/* voxgig/station - one control surface for outbound integrations (C port).
 *
 * The station library core, solo mode (design D1): fully functional
 * in-process with no other component running. The proxy (D2) is a
 * deferred amplifier - `require` therefore fails on the operation path
 * (design station.md 2.1/14), and `auto` degrades to solo with one
 * warning event.
 *
 * A port of the canonical typescript/src sources. TIER C SCOPE
 * (design station.md 2.2, 10.1): solo only - no wire client, no proxy
 * attachment; SECRETS ARE ENV-ONLY, and this library says so: there is
 * no sekreto C port, so the broker reads the process environment
 * directly under the envkey of the secret name (voxgig_solardemo.apikey
 * -> VOXGIG_SOLARDEMO_APIKEY, the same mapping sekreto's envkey()
 * defines and the one the generated SDKs already document). It grows no
 * second provider: a profile whose chain names any other store gets a
 * warning event at open, not a silent partial implementation. And NO
 * station.json FILE LOOKUP: configuration arrives in code (pass the
 * config JSON to vxstn_open), which keeps the vendored surface small.
 * The permanent fix for secrets is a sekreto C port, contributed to
 * sekreto (design station.md 18).
 *
 * The library is standalone C (C99 + POSIX getenv/clock): it carries
 * its own tiny JSON value model (vxstn_val) because the canonical
 * serializer needs one anyway and the C SDKs' voxgig_value machinery
 * ships inside each generated SDK, not as a reusable library (design
 * station.md 10.1). The generated station feature (sdkgen-station's
 * tm/c/feature/station.c) is the bridge: it serializes the SDK's
 * embedded config to JSON, registers here, and delegates transport
 * middleware decisions (require-proxy, host policy, secret value,
 * events) to this library, keeping every rule in one place.
 *
 * THREADING: the generated C SDKs are single-threaded by design (the
 * whole pipeline is synchronous), and this library matches that scope -
 * it is NOT internally synchronized. Design 10.2's concurrency contract
 * applies to threaded runtimes; tier C's host has none.
 *
 * MEMORY: plain malloc. Functions returning char* / vxstn_val* /
 * vxstn_error* return OWNED allocations unless documented as borrowed;
 * vxstn_val_free / vxstn_error_free release trees. Inside a generated C
 * SDK (a retain-heavy, never-free host) leaking these short-lived
 * values is acceptable, matching the host's own discipline.
 *
 * NOTE ON COPIES: the canonical source of this library lives in the
 * voxgig/station repo at c/src/voxgig_station.{h,c}. The sdkgen-station
 * package carries a VENDORED copy under
 * .sdk/tm/c/feature/station/voxgig_station.{h,c} (C has no package
 * registry; design station.md 9.2 vendors tier-C libraries through the
 * tm overlay). Edit HERE first, then refresh the vendored copy - the
 * two must stay byte-identical.
 */

#ifndef VOXGIG_STATION_H
#define VOXGIG_STATION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VXSTN_VERSION "0.0.1"

/* =========================================================================
 * Errors (design station.md 14): <subject>_<condition>, absence as
 * no_<thing>, gates as _allow. The `errors` corpus section pins the
 * exact strings.
 * =========================================================================*/

typedef struct vxstn_error {
  char* code;    /* e.g. "station_secret_no_value" */
  char* message; /* "<code>: <detail>" - the code prefix included, like ts */
} vxstn_error;

vxstn_error* vxstn_error_new(const char* code, const char* msg);
void vxstn_error_free(vxstn_error* err);
bool vxstn_known_code(const char* code);

/* =========================================================================
 * Value model: a tiny JSON tree (insertion-ordered maps), because the
 * canonical serializer and the descriptor need one and the host SDK's
 * voxgig_value is not a reusable library (design station.md 10.1).
 * =========================================================================*/

typedef enum {
  VXSTN_UNDEF = 0, /* absent - distinct from a present null */
  VXSTN_NULL,
  VXSTN_BOOL,
  VXSTN_NUM,
  VXSTN_STR,
  VXSTN_LIST,
  VXSTN_MAP
} vxstn_kind;

typedef struct vxstn_val vxstn_val;

struct vxstn_val {
  vxstn_kind kind;

  bool b;
  /* Numbers carry both reps: integer-shaped JSON stays exact in i
   * (canonical printing of large ints depends on it). */
  bool isint;
  int64_t i;
  double num;

  char* str;

  vxstn_val** items; /* VXSTN_LIST */
  size_t len;
  size_t cap;

  char** keys; /* VXSTN_MAP, insertion ordered */
  vxstn_val** vals;
  size_t mlen;
  size_t mcap;
};

vxstn_val* vxstn_undef(void);
vxstn_val* vxstn_null(void);
vxstn_val* vxstn_bool(bool b);
vxstn_val* vxstn_int(int64_t i);
vxstn_val* vxstn_num(double n);
vxstn_val* vxstn_str(const char* s);
vxstn_val* vxstn_list(void);
vxstn_val* vxstn_map(void);

void vxstn_list_push(vxstn_val* list, vxstn_val* item);      /* takes ownership */
void vxstn_map_set(vxstn_val* map, const char* key, vxstn_val* val); /* ditto */

/* Borrowed reads. Get returns NULL when absent (a present JSON null is
 * a VXSTN_NULL value, not NULL). */
vxstn_val* vxstn_map_get(const vxstn_val* map, const char* key);
vxstn_val* vxstn_list_get(const vxstn_val* list, size_t index);

bool vxstn_is_map(const vxstn_val* v);
bool vxstn_is_list(const vxstn_val* v);
bool vxstn_is_str(const vxstn_val* v);
/* nil-ish: NULL pointer, VXSTN_UNDEF or VXSTN_NULL - "no value" on
 * config surfaces, mirroring the ts `null == v` reads. */
bool vxstn_is_nil(const vxstn_val* v);

/* Borrowed string ("" when not a string). */
const char* vxstn_strval(const vxstn_val* v);

vxstn_val* vxstn_clone(const vxstn_val* v);
void vxstn_val_free(vxstn_val* v);

/* Strict JSON parse. NULL on failure with *errmsg set (owned) when
 * errmsg is non-NULL. Null parses to VXSTN_NULL. */
vxstn_val* vxstn_parse_json(const char* text, char** errmsg);

/* =========================================================================
 * Canonical serialization (design station.md 4): UTF-8, object keys
 * sorted bytewise (strcmp compares as unsigned char, which IS byte
 * order), no insignificant whitespace, minimal JSON escaping, integer-
 * shaped numbers printed as integers. The proxy dedupes registrations
 * by a hash of this, so every port must produce identical bytes - the
 * `canonical` corpus section carries the adversarial cases.
 * =========================================================================*/

char* vxstn_canonical(const vxstn_val* v); /* owned */

/* =========================================================================
 * Identity: envtoken / secret names (design station.md 5.1)
 * =========================================================================*/

/* The ONLY way to build an env-var token in station, mirroring sdkgen's
 * packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
 * `secretname` corpus section pins the round-trip against sekreto's
 * envkey() and sdkgen's envName() - the one place three grammars meet. */
char* vxstn_envtoken(const char* name); /* owned */

/* The default sekreto name for a plugin (design station.md 5.1):
 * envtoken(slug) lowercased, plus '.apikey'. envkey() then yields
 * exactly the env var the SDK's README documents:
 * gnarly_pets.apikey -> GNARLY_PETS_APIKEY. */
char* vxstn_secretname_default(const char* slug); /* owned */

/* Is this a well-formed secret name? sekreto's grammar: dot-separated
 * segments of [a-z0-9_]+ (restated here because there is no sekreto C
 * port to import it from; the grammar is sekreto's, pinned by its
 * spec). */
bool vxstn_validname(const char* name);

/* The environment-variable key for a name: api.token -> API_TOKEN
 * (sekreto's envkey mapping - the one store mapping an env-only library
 * legitimately carries, because it is the mapping it reads by). NULL +
 * *err (station_secret_error) for a malformed name. */
char* vxstn_envkey(const char* name, vxstn_error** err); /* owned */

/* The inert credential placeholder: "[station:<slug>]" (well under the
 * generated prepare_auth's 1024-byte header buffer). */
char* vxstn_placeholder(const char* slug); /* owned */

/* =========================================================================
 * Descriptor (design station.md 4): a view over the SDK's embedded
 * config, normalized - never a second model.
 * =========================================================================*/

/* Normalize a generated SDK's embedded config into descriptor v1.
 * `config` is the value every SDK carries (config.main / .feature /
 * .options / .entity); `active_features` is the client's options.feature
 * map (only each entry's `active` is read; may be NULL). Legacy configs
 * (no main.slug/version/target) get the fixed sentinels and a warning.
 * Returns the descriptor (owned); *warnings_out (when non-NULL) gets an
 * owned LIST of warning strings. */
vxstn_val* vxstn_normalize_descriptor(const vxstn_val* config,
                                      const vxstn_val* active_features,
                                      vxstn_val** warnings_out);

/* =========================================================================
 * Profiles (design station.md 3.5). Tier C carries NO station.json file
 * lookup - config arrives in code - but profile RESOLUTION is the full
 * shared rule: deep-merge per plugin, except secrets.providers which
 * replaces wholesale; a configured secret name sekreto's grammar
 * rejects fails station_secret_name at profile load, not first request.
 * =========================================================================*/

/* Profile selection: the opts profile when non-empty, else
 * VOXGIG_STATION_PROFILE, else 'default'. Owned. */
char* vxstn_select_profile(const char* opt_profile);

/* Resolve profile `profile_name` of `config` (a station.json-shaped
 * value, or NULL/non-map for none). Returns an owned map
 * { name, providers, plugin }, or NULL + *err (station_secret_name). */
vxstn_val* vxstn_resolve_profile(const vxstn_val* config,
                                 const char* profile_name,
                                 vxstn_error** err);

/* =========================================================================
 * The config grammar, as data (design station.md 4). Stage 5.
 *
 * TWO STEPS, AND THE FIRST MAKES THE SECOND HONEST: struct treats a
 * spec node that ends up EMPTY as an open map, and an optional key is
 * removed from the spec node when the data does not carry it - so a
 * block whose keys are all optional degenerates into an open map
 * exactly when the data has none of them. Normalize first, so every
 * container is present; then validate against a shape with NO OPTIONAL
 * CONTAINERS AT ALL, and unexpected-key detection is live at every
 * level.
 *
 * Validation is voxgig/struct's - the second runtime dependency, and
 * the only one besides the environment this tier reads secrets from.
 * =========================================================================*/

/* Materialize every documented default into a COPY of `raw`; the input
 * is never mutated, and a node that is not the kind it expects is left
 * alone for validation to reject by path. A non-map `raw` is returned
 * (copied) unchanged. Owned. */
vxstn_val* vxstn_normalize_config(const vxstn_val* raw);

/* Run the shape over the NORMALIZED form, then the design 4.4 and 5.2
 * scans. Returns an owned copy of the input, or NULL + *err:
 * station_config_invalid (struct's own errors and the 4.4 explicit
 * checks, EVERY ONE AT ONCE, joined with "; "), station_feature_reserved
 * (`feature.station` at any level, `options.feature` at any depth), or
 * station_config_secret (credential-shaped keys, bad `secret` values,
 * URL userinfo). */
vxstn_val* vxstn_validate_config(const vxstn_val* normalized, vxstn_error** err);

/* A FRESH DEEP COPY of spec/config-shape.json on every call: struct's
 * validate CONSUMES the spec it walks (it deletes satisfied `$ONE`
 * branches), so one parsed constant cannot serve two validations.
 * Owned. */
vxstn_val* vxstn_config_shape(void);

/* The mirrored shape bytes (src/config_shape.h, generated by `make
 * sync-shape`). Borrowed; the drift check in test/unit.c compares them
 * against spec/config-shape.json. */
const char* vxstn_config_shape_json(void);

/* The defaults tables, as fresh maps - ONE table, TWO CALLERS AT
 * DIFFERENT MOMENTS. vxstn_validate_config applies the block defaults
 * BEFORE the shape run (a block with no present keys is an open map);
 * the profile resolver applies them AFTER the merge (an absent key must
 * stay absent through it, or a one-key overlay silently re-enables an
 * integration the base barred). Owned. */
vxstn_val* vxstn_profile_defaults(void);
vxstn_val* vxstn_block_defaults(void);

/* The block defaults that must NOT be synthesized before the profile
 * merge: exactly {"active"}, NULL-terminated. Named rather than
 * inferred so a test can assert it. */
extern const char* const VXSTN_MERGE_SENSITIVE[];

/* =========================================================================
 * The instance ref grammar (design station.md 6.1) and the factory
 * table (6.2). Stage 5.
 * =========================================================================*/

/* The api half of a ref: the substring before the first `$`, and an
 * untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
 * point: under the old free-form identity which api an instance used
 * was itself a merged value, so a port that got the phasing wrong
 * silently picked another api's defaults. Owned. */
char* vxstn_refapi(const char* ref);

/* `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, 1..1024 characters. */
bool vxstn_check_instance_name(const char* name);

/* The empty tag is valid; otherwise `^[a-zA-Z0-9.~_-]+$`, up to 1024.
 * A tag MAY start with a digit (auto-tagging assigns integer tags) and
 * admits neither `@` nor `/`. */
bool vxstn_check_instance_tag(const char* tag);

/* Validate a ref (split on the FIRST `$`) and return its CANONICAL
 * spelling - a trailing `$` is never kept, so "stripe$" and "stripe"
 * are one registry key. Owned, or NULL + *err (station_instance_api). */
char* vxstn_check_ref(const char* ref, vxstn_error** err);

/* design 6.1's rule over (api, feature options): `instance` wins over
 * `as`; a bare call returns the validated api slug; a `$`-less `as` is
 * ALWAYS A TAG and yields api+"$"+as; a `$`-bearing value is a full ref
 * validated against the api. Owned, or NULL + *err. */
char* vxstn_instance_ref(const char* api, const vxstn_val* fopts, vxstn_error** err);

/* Construct one client of an api from the options station composed.
 * The generated constructor's C spelling; `ud` is whatever the SDK
 * handed to vxstn_provide. */
typedef void* (*vxstn_construct_fn)(const vxstn_val* options, void* ud);

/* A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG (design
 * 6.2): station composes the ordered feature array FOR the constructor,
 * so it needs the feature option schemas and transport roles BEFORE
 * construction, and the descriptor is normalized at PROVIDE time. */
typedef struct {
  char* api;
  vxstn_construct_fn construct;
  void* ud;
  vxstn_val* config;     /* the SDK's embedded config (copied) */
  vxstn_val* descriptor; /* normalized at provide time, no active features */
  vxstn_val* warnings;   /* list of strings, from that normalization */
} vxstn_factory;

/* Register an api's factory in the PROCESS-GLOBAL table. Idempotent for
 * an identical pair (same constructor, same user data, same config
 * bytes); NULL + *err (station_factory_conflict) for a different one.
 * Borrowed - the table owns the entry.
 *
 * THIS IS THE ONLY WAY THE TABLE GETS FILLED IN C: there is no runtime
 * module loading and no module-init hook to self-register through, so
 * `api.<slug>.package` is not honoured here (open() warns once per
 * declared package). README.md states the divergence. */
const vxstn_factory* vxstn_provide(const char* api, vxstn_construct_fn construct,
                                   void* ud, const vxstn_val* config,
                                   vxstn_error** err);

/* The registered factory for an api, or NULL. Borrowed. */
const vxstn_factory* vxstn_factory_for(const char* api);

/* The api slugs currently registered, sorted. Owned. */
vxstn_val* vxstn_provided(void);

/* Test seam: empty the process-global table. */
void vxstn_reset_factories(void);

/* Reject anything that is not a bare module name - empty, a leading
 * `.`, `/` or `~`, any `.`/`..` path segment, any "://", any backslash -
 * with station_sdk_load. A PURE VALIDATOR here: C has no loader, so
 * nothing in this port ever imports a `package`; the check exists so a
 * config shared with a loader port fails the same way in both. */
bool vxstn_check_package(const char* api, const char* pkg, vxstn_error** err);

/* =========================================================================
 * Feature management (design station.md 8). Stage 5.
 *
 * Pure data in, data out - no station handle and no SDK - which is what
 * lets the `feature` corpus section pin it.
 * =========================================================================*/

/* Reserved on a feature entry: not options, never passed through to the
 * SDK's own option map. {"active", "order"}, NULL-terminated. */
extern const char* const VXSTN_RESERVED_KEYS[];

/* Bands. HIGHER IS FURTHER IN: `test` substitutes the base transport so
 * it takes the innermost band, `station` sits immediately outside it,
 * everything else is band 0. */
#define VXSTN_BAND_DEFAULT 0
#define VXSTN_BAND_STATION 100
#define VXSTN_BAND_TEST 200

int vxstn_default_band(const char* name);

/* A feature named in the config is one you are ASKING for: active
 * unless it is exactly boolean false, or its `active` is. */
bool vxstn_feature_active(const vxstn_val* entry);

/* The two-level merge (per feature name, then per option key, NEVER
 * deeper) over the sources left to right; a non-map entry replaces
 * wholesale. NO DEFAULTS ARE SYNTHESIZED - the caller passes RAW
 * blocks. `sources` is a LIST of maps. Owned. */
vxstn_val* vxstn_merge_features(const vxstn_val* sources);

/* The six sources for one instance, in design 3.3's order extended by
 * the profile level: base.feature, base.api[api].feature,
 * base.sdk[ref].feature, then the same three from the overlay. An
 * absent level is an undef entry, so the list is always six long.
 * Owned. */
vxstn_val* vxstn_feature_sources(const vxstn_val* base, const vxstn_val* overlay,
                                 const char* api, const char* ref);

/* The stable constraint-and-band topological sort of the ACTIVE
 * entries, OUTERMOST FIRST: a list of { name, band, entry }. NULL +
 * *err (station_feature_order) when the constraints form a cycle.
 * Owned. */
vxstn_val* vxstn_resolve_order(const vxstn_val* merged, vxstn_error** err);

/* station's position is PINNED INNERMOST (design 8.4): immediately
 * outside the `test` base transport, or last when there is none.
 * Returns an owned station_feature_order error when an ordering moved
 * it, else NULL. */
vxstn_error* vxstn_check_pin(const vxstn_val* ordered);

/* Project the ordered rows into the ARRAY FORM the generated
 * constructor accepts: { name, active: true, ...entry minus the
 * reserved keys }. Owned. */
vxstn_val* vxstn_compose_features(const vxstn_val* ordered);

/* The design 8.5 checker, derived from the descriptor and never
 * hand-written. COLLECTS, never fails: an owned list of
 * { code, feature, key?, message }, in sorted feature/option order.
 * The callers own the error. */
vxstn_val* vxstn_check_features(const vxstn_val* merged, const vxstn_val* descriptor);

/* =========================================================================
 * The Station (design D1: the in-process hub, solo mode)
 * =========================================================================*/

typedef struct vxstn_station vxstn_station;

typedef struct vxstn_open_opts {
  const char* profile;     /* NULL/'' -> env VOXGIG_STATION_PROFILE, else default */
  const char* proxy;       /* NULL -> "auto"; "off" | "require" | <url> */
  const char* config_json; /* station.json content, in code (tier C: no
                            * file lookup); NULL -> no config */
  int event_max;           /* ring capacity; 0 -> default 1000 */
  /* design 6.3's review boundary. 0 = unset, which means TRUE here: a
   * config that arrives in code was written by the application, so it
   * is repo-scoped by construction, and this tier reads no user-level
   * file to distrust. 1 = yes, -1 = no. THE EXPLICIT VALUE IS READ
   * FIRST - inferring before reading it makes -1 unsettable for the one
   * caller that can set it. */
  int repo_scoped;
  /* Accepted and INERT (design 5.4 item 4): this port has no loader, so
   * there is nothing to switch off. Kept so a caller that writes
   * `load: false` for its js sibling is not refused here. */
  bool no_load;
} vxstn_open_opts;

/* Ambient instance (design station.md 10.2): open() is the idempotent
 * process-wide singleton; a second open() with conflicting options is
 * an error (station_open_conflict); vxstn_station_new stays isolated
 * for tests. open() is non-blocking - solo involves no network, and the
 * deferred proxy probe must never change that. NULL opts = defaults.
 * Returns NULL + *err on failure. */
vxstn_station* vxstn_open(const vxstn_open_opts* opts, vxstn_error** err);

/* The ambient instance, or NULL - never creates one. The generated
 * station feature binds through this when no explicit handle rides its
 * options (design station.md 3.1: binding is never implicit; only
 * open() creates the ambient instance). */
vxstn_station* vxstn_current(void);

/* Test seam: drop the ambient instance (does not free it - the host is
 * never-free; an isolated test that cares calls vxstn_station_free). */
void vxstn_reset(void);

/* An isolated instance (tests, multi-tenant hosts). */
vxstn_station* vxstn_station_new(const vxstn_open_opts* opts, vxstn_error** err);
void vxstn_station_free(vxstn_station* st);

/* close(): solo has nothing in flight; warns on profile plugin keys
 * that matched no registered plugin - a typo'd key silently configuring
 * nothing is the worst outcome for a secrets-and-policy file (design
 * station.md 11). Idempotent. Drops the ambient slot when it is this
 * instance. */
void vxstn_close(vxstn_station* st);

/* --- registration (design station.md 3 item 1, called by the adapter) --- */

typedef struct vxstn_binding {
  char* plugin;      /* THE INSTANCE NAME - "stripe" or "stripe$test".
                      * Every later seam (rung, host policy, secret
                      * value, events) takes this, not the api slug. */
  char* api;         /* the api slug, which groups an instance with its
                      * siblings; equal to `plugin` when untagged */
  char* placeholder; /* NULL when auth is inactive; keyed on the INSTANCE
                      * so two live instances of one api never share one */
  char* secretname;  /* effective secret name; NULL when auth inactive */
  char* rung;        /* "R1" | "none" */
  /* design 16's solo half: the profile policy's allowlists, joined with
   * "," for the SDK's own `options.allow`, or NULL when the block sets
   * none. An allowlist is ENFORCEMENT, not a default: the adapter
   * applies these OVER whatever the options already carry, unlike
   * `base`, which the caller may override. */
  char* allow_op;
  char* allow_method;
} vxstn_binding;

void vxstn_binding_free(vxstn_binding* b);

/* Register a plugin from its embedded config (as JSON text - the
 * adapter serializes the SDK's config value) plus the client's
 * options.feature map as JSON (only `active` flags are read) and the
 * feature-options secret override ('' / NULL = none). `client` is an
 * opaque identity pointer for the bound-twice check. Emits the legacy
 * warnings and the construct event. NULL + *err on station_bound_twice
 * (same slug twice) or unparseable config. */
vxstn_binding* vxstn_register(vxstn_station* st, void* client,
                              const char* config_json,
                              const char* features_json,
                              const char* secret_opt,
                              vxstn_error** err);

/* Is this client already bound? (Idempotency seam: one client, one
 * binding - a second arrival must no-op; a second CLIENT of the same
 * SDK still fails register's slug check. Design 10.2.) */
bool vxstn_bound(vxstn_station* st, void* client);

/* --- the transport middleware seams (design station.md 3.3, 5.3) ---
 * The generated adapter owns the SDK-typed wrap; every DECISION lives
 * here. */

/* Fail-closed means traffic (design 2.1): with the proxy deferred,
 * `require` can never attach, so every operation must fail
 * station_no_proxy on the operation path - never the constructor. */
bool vxstn_require_proxy(vxstn_station* st);

/* Hosts allowlist (design station.md 16, solo half). *has_policy tells
 * the adapter to ask the transport for manual redirects (design 8.2's
 * rule at the library seam). Returns false only when a policy exists
 * and the URL's hostname is not on it. */
bool vxstn_host_allowed(vxstn_station* st, const char* slug,
                        const char* fullurl, bool* has_policy);

/* The plugin's isolation rung: "R1" | "none" (borrowed; NULL when the
 * slug is unknown). Injection happens only on R1 - and, adapter-side,
 * only in live mode: never into mock transports (design 3.3). */
const char* vxstn_rung(vxstn_station* st, const char* slug);

/* Resolve the secret value for a registered plugin (override beats
 * cache beats environment). ENV-ONLY, keeping sekreto's miss-vs-error
 * distinction (design 5.2): an unset variable is
 * station_secret_no_value; a set-but-empty variable is a present
 * (empty) value; station_secret_error is reserved for malformed names,
 * because the environment cannot "fail to answer". Returns a BORROWED
 * value (held privately by the broker), or NULL + *err. */
const char* vxstn_secret_value(vxstn_station* st, const char* slug,
                               vxstn_error** err);

/* Hoist a resident credential (found in options.apikey at bind time)
 * into the broker and emit the one-time warning event (design 3.1). */
void vxstn_hoist(vxstn_station* st, const char* slug, const char* value);

/* The next correlation id ("c1", "c2", ...), owned. Correlates op and
 * http events (design station.md 3 item 3). */
char* vxstn_next_corr(vxstn_station* st);

/* Op outcome from the SDK result (design station.md 3 item 3): no
 * result -> "unknown"; an error or ok=false -> "err"; else "ok". */
const char* vxstn_outcome(bool has_result, bool has_err, bool ok);

/* Position guard input check (design station.md 3.3): `names` is the
 * client's feature list in init order. Strays named "base" are excluded
 * before the check - the generated C make_feature FALLS BACK to an
 * inert base feature for unknown names, and a base feature can never
 * wrap or record the transport - so the guard keeps its actual meaning:
 * nothing that could wrap sits between the base transport and station.
 * Returns NULL when station sits immediately after test (or first, with
 * no test), else an owned station_wrap_order error. */
vxstn_error* vxstn_wrap_order_check(const char* const* names, size_t n);

/* --- event emission (design station.md 6) --- */

/* Wire-truth http event (one per attempt). Parses host/path from the
 * URL; durationMs = now - started_ms. */
void vxstn_emit_http(vxstn_station* st, const char* slug, const char* corr,
                     const char* method, const char* fullurl,
                     int64_t status, int64_t started_ms, int64_t bytes);

/* Error event; the message is scrubbed (exact-value, no length floor -
 * design 7 as revised) before it enters the stream. */
void vxstn_emit_err(vxstn_station* st, const char* slug, const char* corr,
                    const char* code, const char* message);

/* Operation event from the hook bridge. */
void vxstn_emit_op(vxstn_station* st, const char* slug, const char* corr,
                   const char* entity, const char* op, const char* outcome,
                   int64_t duration_ms);

/* A station-kind warning event. */
void vxstn_emit_warn(vxstn_station* st, const char* slug, const char* warn);

/* --- the query/observe surface (design station.md 3.2, 6) --- */

/* Owned deep copy of the buffered events (a bounded ring; overflow
 * drops oldest and the drop count is visible in status). Events are
 * COPIED out, never aliased - the host SDK mutates in place. */
vxstn_val* vxstn_events(vxstn_station* st);

/* Live subscription; callbacks are serialized (single-threaded host)
 * and must not longjmp. Returns a tap id for vxstn_untap. The event is
 * BORROWED for the duration of the call. */
typedef void (*vxstn_tap_fn)(void* ud, const vxstn_val* ev);
int vxstn_tap(vxstn_station* st, vxstn_tap_fn fn, void* ud);
void vxstn_untap(vxstn_station* st, int tap_id);

/* { mode: "solo", profile, plugins: [{slug, rung}], events: {buffered,
 * dropped}, secrets: "env-only" } - env-only stated where an operator
 * will read it (design 2.2). Owned. */
vxstn_val* vxstn_status(vxstn_station* st);

/* Registered plugins: [{slug, descriptor, rung, warnings}]. Owned. */
vxstn_val* vxstn_plugins(vxstn_station* st);

/* The descriptor of a registered plugin (owned copy), or NULL + *err
 * (station_no_plugin, listing the known slugs). */
vxstn_val* vxstn_descriptor_of(vxstn_station* st, const char* slug,
                               vxstn_error** err);

/* Canonical bytes of the descriptor (owned), or NULL + *err. */
char* vxstn_canonical_descriptor(vxstn_station* st, const char* slug,
                                 vxstn_error** err);

/* Exact-value scrub of every value the broker ever held (owned). */
char* vxstn_redact(vxstn_station* st, const char* text);

/* Drop the secret cache so the next resolve asks the environment again
 * (rotation support, design 5.3). */
void vxstn_refresh_secrets(vxstn_station* st);

/* The resolved profile's plugin entry for a slug (borrowed; NULL when
 * none). The adapter reads policy through vxstn_host_allowed; this is
 * for tests and status surfaces. */
const vxstn_val* vxstn_profile_sdk(vxstn_station* st, const char* slug);

/* =========================================================================
 * The declarative front door (design station.md 6). Stage 5.
 *
 * "Write it once in station.json, get it where you need it": the
 * instance table comes from the resolved profile, the CONSTRUCTOR from
 * the factory table, and the feature merge, the order, the 8.5 check
 * and the options are composed between them.
 *
 * THE C DIVERGENCE (design 6.3, 5.4): there is no loader. An api
 * reaches the table through vxstn_provide and nothing else, and a
 * declared `package` is a warning event at open, never an import.
 * =========================================================================*/

/* The instance, constructed on FIRST call and CACHED by name.
 * Synchronous. NULL + *err: station_no_instance (nothing declares it),
 * station_instance_inactive (`active: false`), station_no_factory (no
 * vxstn_provide for its api), station_feature_unknown /
 * station_feature_option (design 8.5), station_feature_order.
 * The client is owned by whatever the factory's constructor returns;
 * the station only caches the pointer. */
void* vxstn_sdk(vxstn_station* st, const char* name, vxstn_error** err);

/* An UNCACHED client of a declared instance, registered under an
 * auto-assigned integer tag - the per-request or test-double case.
 * `overrides` (may be NULL) is merged over the block's options, and its
 * `feature` map over the composed one. */
void* vxstn_create(vxstn_station* st, const char* name, const vxstn_val* overrides,
                   vxstn_error** err);

/* The lowest positive integer tag not taken by a LIVE or a DECLARED
 * instance of that api. Owned. */
char* vxstn_autotag(vxstn_station* st, const char* name);

/* The registered factory for an api, or NULL + *err
 * (station_no_factory) - naming only the remedies THIS port offers.
 * Borrowed. */
const vxstn_factory* vxstn_resolve_factory(vxstn_station* st, const char* api,
                                           const vxstn_val* block,
                                           vxstn_error** err);

/* The merged feature set for one instance with PER-VALUE PROVENANCE
 * (design 8.7), the policy.budget -> ratelimit composition, and the
 * implicit `station` row used for the pin check:
 * { ordered: [name...], merged, from: { feature: { key: level } } }.
 * Owned, or NULL + *err (station_feature_order). */
vxstn_val* vxstn_features_of(vxstn_station* st, const char* name, vxstn_error** err);

/* The fleet view: one row per instance passing the filter, each
 * { instance, api, ordered, merged, from }. `filter` may be NULL, a
 * STRING (loose "this instance or this api") or a map
 * { instance?, api?, feature? }; a `feature` filter narrows both the
 * rows and each row's contents. Owned. */
vxstn_val* vxstn_features(vxstn_station* st, const vxstn_val* filter);

/* Eagerly validate and construct every ACTIVE declared instance:
 * { ok: [name...], failed: [{ name, code, message }] }. Owned. */
vxstn_val* vxstn_check(vxstn_station* st);

/* Batch-resolve secrets: { warmed, missed }, both sorted. With NULL it
 * warms the ACTIVE declared instances; with a list of names it warms
 * exactly those, inactive included. Deduplicated by SECRET NAME, and
 * resolved SERIALLY - C has no async idiom, and the deduplication is
 * the half that matters (the broker's cache is keyed by secret name).
 * A name neither registered nor declared is a MISS, never a lookup.
 * Owned. */
vxstn_val* vxstn_warm(vxstn_station* st, const vxstn_val* names);

/* Every DECLARED instance, sorted by name:
 * { name, api, active, live, rung, block }. A different question from
 * vxstn_plugins(), which lists the LIVE ones. Owned. */
vxstn_val* vxstn_instances(vxstn_station* st);

/* The profile block that governs an instance: its own if the profile
 * declares it, otherwise its API's. ONE RULE, ONE PLACE - registration
 * and the transport seam both ask here. Borrowed; NULL when neither
 * level declares anything. */
const vxstn_val* vxstn_block_for(vxstn_station* st, const char* name);

/* The DECLARED instance an auto-assigned tag stands for, else the name
 * itself. Borrowed. */
const char* vxstn_declared_ref(vxstn_station* st, const char* name);

/* The inverted binding (design 3.1): the options map a generated
 * constructor accepts, with the station activation entry and the
 * instance name in it. `instance` is OPTIONAL (NULL) and LEADING.
 * The station HANDLE does not ride the map - a C value tree holds JSON,
 * not pointers - so the generated feature binds to the ambient instance
 * or to a handle the host gives it. Owned. */
vxstn_val* vxstn_options(vxstn_station* st, const char* instance,
                         const vxstn_val* extra);

/* design 6.3's review boundary: true unless the caller set
 * `repo_scoped = -1`. This tier reads no station.json file, so there is
 * no user-level config to distrust and no scope to discover. */
bool vxstn_repo_scoped(vxstn_station* st);

/* Milliseconds since the epoch (event timestamps). */
int64_t vxstn_now_ms(void);

#endif /* VOXGIG_STATION_H */
