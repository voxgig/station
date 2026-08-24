// RUN: make test  (cargo test, after `make vendor`)
//
// Focused unit tests for the pieces the corpus cannot see: the event
// ring/tap, the broker's miss-vs-error split and floorless scrub, the
// bind() guards (wrap order, second arrival, bound twice, inert without
// an open station), the per-request prepare() decisions (require,
// hosts policy + manual redirects, injection, mock non-injection), the
// station.json lookup walk, and - since Stage 5's later tranche - the
// declarative front door: the factory table, sdk()/create()/build(),
// features_of's provenance and budget composition, warm(), check(), and
// the drift guard on the embedded shape mirror. Each test thread gets
// its own ambient instance and its own factory table (both
// thread-local), so tests stay isolated without a lock - and each test
// that uses either resets it first, for the case where the harness runs
// them on one thread.

use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::rc::Rc;

use voxgig_station::{
    bind, camelify, canonical_serialize, check_features, check_package, config_scope, config_shape,
    config_shape_json, find_config_file, jget, jobj, jstr, jtext, normalize_config,
    normalize_descriptor, placeholder_for, provide, provided, reset_factories, validate_config,
    BindSpec, ConfigSource, EventBuffer, Factory, Json, SecretBroker, Station, StationEvent,
    StationOptions, MERGE_SENSITIVE,
};

fn parse(text: &str) -> Json {
    voxgig_sekreto::json::parse(text).expect("json")
}

// A panic payload's text, whether it was a literal (&str) or formatted
// (String).
fn panic_text(payload: &Box<dyn Any + Send>) -> String {
    if let Some(text) = payload.downcast_ref::<String>() {
        return text.clone();
    }
    if let Some(text) = payload.downcast_ref::<&str>() {
        return text.to_string();
    }
    String::new()
}

// A taskpad-shaped embedded config (the descriptor's input).
fn config() -> Json {
    parse(
        r#"{
          "main": { "name": "Taskpad", "slug": "taskpad", "version": "0.0.1", "target": "rust" },
          "feature": { "test": {} },
          "options": { "base": "http://api.test", "auth": { "prefix": "" }, "entity": { "todo": {} } },
          "entity": { "todo": { "fields": [ { "name": "title", "kind": "String" } ],
            "op": { "list": { "points": [ { "method": "GET", "orig": "/api/todo", "parts": ["api", "todo"] } ] } } } }
        }"#,
    )
}

fn station_config(profile_extra: &str) -> Json {
    parse(&format!(
        r#"{{ "station": 1, "profiles": {{ "default": {{
             "secrets": {{ "providers": [ {{ "kind": "memory",
               "values": {{ "TASKPAD_APIKEY": "sekrit-101" }} }} ] }}{}
           }} }} }}"#,
        profile_extra
    ))
}

fn open_station(config: Json) -> Rc<Station> {
    Station::open(StationOptions {
        config: ConfigSource::Value(config),
        ..Default::default()
    })
}

fn spec(client: Rc<dyn Any>, names: &[&str]) -> BindSpec {
    BindSpec {
        client,
        config: config(),
        feature_names: names.iter().map(|n| n.to_string()).collect(),
        active_features: jobj(vec![(
            "station",
            jobj(vec![("active", Json::Bool(true))]),
        )]),
        feature_opts: jobj(vec![("active", Json::Bool(true))]),
        options_base: "http://api.test".to_string(),
        config_base: "http://api.test".to_string(),
        resident_apikey: String::new(),
    }
}

fn events_of(station: &Station, kind: &str) -> Vec<StationEvent> {
    station
        .events()
        .into_iter()
        .filter(|ev| kind == ev.kind)
        .collect()
}

// --- events -----------------------------------------------------------------

#[test]
fn events_ring_drops_oldest_and_counts() {
    let buffer = EventBuffer::new(Some(2));
    for at in 0..3 {
        buffer.emit(StationEvent {
            t: at,
            kind: "station".to_string(),
            ..Default::default()
        });
    }
    let events = buffer.events();
    assert_eq!(2, events.len(), "ring capped");
    assert_eq!(1, events[0].t, "oldest dropped");
    assert_eq!((2usize, 1i64), buffer.status(), "drop counted");
}

#[test]
fn events_tap_untap_and_panicking_tap_tolerated() {
    let buffer = EventBuffer::new(None);
    let seen: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    let sc = seen.clone();
    let id = buffer.tap(Rc::new(move |ev| sc.borrow_mut().push(ev.kind.clone())));
    let _boom = buffer.tap(Rc::new(|_ev| panic!("tap boom")));

    buffer.emit(StationEvent {
        kind: "op".to_string(),
        ..Default::default()
    });
    assert_eq!(vec!["op".to_string()], *seen.borrow(), "tap saw the event");

    buffer.untap(id);
    buffer.emit(StationEvent {
        kind: "http".to_string(),
        ..Default::default()
    });
    assert_eq!(1, seen.borrow().len(), "untapped");
}

// --- secrets ----------------------------------------------------------------

#[test]
fn broker_miss_is_no_value_error_is_error() {
    // A miss: the chain ran and no store had the name (design §5.2).
    let broker = SecretBroker::new(&[parse(r#"{ "kind": "memory", "values": {} }"#)]).unwrap();
    let miss = broker.value("taskpad", "taskpad.apikey").unwrap_err();
    assert_eq!("station_secret_no_value", miss.code);

    // An error: a store that could not answer - never treated as a miss.
    let broker = SecretBroker::new(&[
        parse(r#"{ "kind": "memory", "values": {} }"#),
        parse(r#"{ "kind": "boru", "command": "/definitely/not/a/command" }"#),
    ])
    .unwrap();
    let err = broker.value("taskpad", "taskpad.apikey").unwrap_err();
    assert_eq!("station_secret_error", err.code);
    assert!(
        err.msg.contains("cannot run"),
        "sekreto's message intact: {}",
        err.msg
    );
}

#[test]
fn broker_scrub_has_no_length_floor() {
    let broker = SecretBroker::new(&[parse(r#"{ "kind": "memory", "values": {} }"#)]).unwrap();
    // Three characters: under sekreto's own redact() floor, still scrubbed
    // exactly on station boundaries (design §7 as revised).
    broker.hoist("taskpad", "abc");
    assert_eq!("key=[redacted]!", broker.scrub("key=abc!"));
}

// --- profile lookup ---------------------------------------------------------

#[test]
fn config_file_lookup_walks_up_to_the_repo_root() {
    let root = std::env::temp_dir().join(format!("station-unit-{}", std::process::id()));
    let sub = root.join("a").join("b");
    std::fs::create_dir_all(&sub).unwrap();
    // A .git marker makes `root` the repo root: the walk must stop there.
    std::fs::create_dir_all(root.join(".git")).unwrap();

    assert_eq!(None, find_config_file(Some(&sub)).filter(|p| p.starts_with(&root)));

    std::fs::write(root.join("station.json"), "{ \"station\": 1 }").unwrap();
    let found = find_config_file(Some(&sub)).expect("found");
    assert_eq!(root.join("station.json"), found);

    std::fs::remove_dir_all(&root).ok();
}

// --- bind() -----------------------------------------------------------------

#[test]
fn bind_without_open_station_is_inert() {
    Station::reset();
    let client: Rc<dyn Any> = Rc::new(());
    assert!(bind(spec(client, &["test", "station"])).is_none());
}

#[test]
fn bind_verifies_wrap_position() {
    let station = open_station(station_config(""));
    let client: Rc<dyn Any> = Rc::new(());

    // station AFTER retry (outside a recording feature) must fail loudly.
    let bad = spec(client, &["test", "retry", "station"]);
    let panicked = catch_unwind(AssertUnwindSafe(|| bind(bad).map(|_| ()))).unwrap_err();
    let text = panic_text(&panicked);
    assert!(
        text.contains("station_wrap_order"),
        "wrap-order code in panic: {}",
        text
    );
    station.close();
    Station::reset();
}

#[test]
fn bind_registers_plants_placeholder_and_dedupes() {
    let station = open_station(station_config(""));
    let client: Rc<dyn Any> = Rc::new(());

    let bound = bind(spec(client.clone(), &["test", "station"])).expect("bound");
    assert_eq!("taskpad", bound.binding.name);
    assert_eq!(Some(placeholder_for("taskpad")), bound.placeholder);

    let construct = events_of(&station, "construct");
    assert_eq!(1, construct.len(), "one construct event");
    assert_eq!(Some("taskpad".to_string()), construct[0].plugin);

    // Same construction, second arrival: inert, not an error.
    assert!(bind(spec(client, &["test", "station"])).is_none());

    // A genuinely second client of the same SDK class: bound twice.
    let other: Rc<dyn Any> = Rc::new(());
    let panicked =
        catch_unwind(AssertUnwindSafe(|| bind(spec(other, &["test", "station"])).map(|_| ())))
            .unwrap_err();
    let text = panic_text(&panicked);
    assert!(
        text.contains("station_bound_twice"),
        "bound-twice code in panic: {}",
        text
    );
    station.close();
    Station::reset();
}

#[test]
fn bind_hoists_a_resident_credential() {
    let station = open_station(station_config(""));
    let client: Rc<dyn Any> = Rc::new(());

    let mut with_resident = spec(client, &["test", "station"]);
    with_resident.resident_apikey = "resident-key".to_string();
    let bound = bind(with_resident).expect("bound");

    let warns: Vec<StationEvent> = events_of(&station, "station")
        .into_iter()
        .filter(|ev| {
            format!("{:?}", ev.meta).contains("hoisted")
        })
        .collect();
    assert_eq!(1, warns.len(), "one hoist warning");

    // The hoisted value now scrubs, and injection uses it.
    assert_eq!("[redacted]", station.redact("resident-key"));

    let headers: BTreeMap<String, String> = BTreeMap::from([(
        "authorization".to_string(),
        placeholder_for("taskpad"),
    )]);
    let plan = bound
        .binding
        .prepare(None, true, "http://api.test/api/todo", &headers)
        .expect("plan");
    assert_eq!(
        Some("resident-key".to_string()),
        plan.headers.and_then(|h| h.get("authorization").cloned()),
        "hoisted value injected"
    );
    station.close();
    Station::reset();
}

// --- prepare() --------------------------------------------------------------

#[test]
fn prepare_injects_only_when_live() {
    let station = open_station(station_config(""));
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");

    let headers: BTreeMap<String, String> = BTreeMap::from([
        ("authorization".to_string(), placeholder_for("taskpad")),
        ("x-plain".to_string(), "keep".to_string()),
    ]);

    // Live: the placeholder is swapped for the broker's value, other
    // headers ride through, the input map is untouched.
    let plan = bound
        .binding
        .prepare(Some("c1".to_string()), true, "http://api.test/api/todo", &headers)
        .expect("plan");
    let injected = plan.headers.expect("injected header set");
    assert_eq!(Some(&"sekrit-101".to_string()), injected.get("authorization"));
    assert_eq!(Some(&"keep".to_string()), injected.get("x-plain"));
    assert_eq!(placeholder_for("taskpad"), headers["authorization"], "input untouched");
    assert!(!plan.manual_redirect, "no hosts policy, no redirect pin");

    // Mock (test) transport: never inject - real credentials must not
    // enter in-memory mock stores (design §3.3).
    let plan = bound
        .binding
        .prepare(None, false, "http://api.test/api/todo", &headers)
        .expect("plan");
    assert!(plan.headers.is_none(), "no injection into mocks");
    station.close();
    Station::reset();
}

#[test]
fn prepare_missing_secret_fails_the_op_path() {
    let station = open_station(parse(
        r#"{ "station": 1, "profiles": { "default": {
             "secrets": { "providers": [ { "kind": "memory", "values": {} } ] } } } }"#,
    ));
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");

    let headers = BTreeMap::new();
    let err = bound
        .binding
        .prepare(Some("c9".to_string()), true, "http://api.test/api/todo", &headers)
        .unwrap_err();
    assert_eq!("station_secret_no_value", err.code);

    let errs = events_of(&station, "error");
    assert_eq!(1, errs.len(), "one error event");
    assert_eq!(
        Some("station_secret_no_value".to_string()),
        errs[0].err.as_ref().and_then(|e| e.code.clone())
    );
    assert_eq!(Some("c9".to_string()), errs[0].corr, "correlated");
    station.close();
    Station::reset();
}

#[test]
fn prepare_enforces_hosts_policy_and_pins_redirects() {
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": { "policy": { "hosts": ["api.test"] } } }"#,
    ));
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");
    let headers = BTreeMap::new();

    // On-list: allowed, and redirects come back manual (§8.2 at the seam).
    let plan = bound
        .binding
        .prepare(None, true, "http://api.test:8080/api/todo", &headers)
        .expect("plan");
    assert!(plan.manual_redirect, "hosts policy pins redirects manual");

    // Off-list: denied before any send.
    let err = bound
        .binding
        .prepare(None, true, "http://evil.example/api/todo", &headers)
        .unwrap_err();
    assert_eq!("station_host_allow", err.code);

    // Mock traffic is not policed (live only, like the canonical port).
    assert!(bound
        .binding
        .prepare(None, false, "http://evil.example/x", &headers)
        .is_ok());
    station.close();
    Station::reset();
}

#[test]
fn prepare_fails_closed_under_require() {
    Station::reset();
    let station = Station::open(StationOptions {
        proxy: Some("require".to_string()),
        config: ConfigSource::Value(station_config("")),
        ..Default::default()
    });
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");

    let err = bound
        .binding
        .prepare(None, true, "http://api.test/api/todo", &BTreeMap::new())
        .unwrap_err();
    assert_eq!("station_no_proxy", err.code);
    station.close();
    Station::reset();
}

// --- secret-name precedence -------------------------------------------------

#[test]
fn feature_secret_option_beats_profile_beats_default() {
    let station = open_station(parse(
        r#"{ "station": 1, "profiles": { "default": {
             "secrets": { "providers": [ { "kind": "memory", "values": {
               "TASKPAD_APIKEY": "from-default",
               "PROFILE_NAMED": "from-profile",
               "CODE_NAMED": "from-code" } } ] },
             "sdk": { "taskpad": { "secret": "profile.named" } } } } }"#,
    ));
    let client: Rc<dyn Any> = Rc::new(());

    let mut with_code = spec(client, &["test", "station"]);
    with_code.feature_opts = jobj(vec![
        ("active", Json::Bool(true)),
        ("secret", jtext("code.named")),
    ]);
    let bound = bind(with_code).expect("bound");

    let headers: BTreeMap<String, String> = BTreeMap::from([(
        "authorization".to_string(),
        placeholder_for("taskpad"),
    )]);
    let plan = bound
        .binding
        .prepare(None, true, "http://api.test/x", &headers)
        .expect("plan");
    assert_eq!(
        Some("from-code".to_string()),
        plan.headers.and_then(|h| h.get("authorization").cloned()),
        "the in-code secret option wins"
    );
    station.close();
    Station::reset();
}

// --- ambient / lifecycle ----------------------------------------------------

#[test]
fn open_is_idempotent_and_conflicts_loudly() {
    Station::reset();
    let first = Station::open(StationOptions::no_config());
    let again = Station::open(StationOptions::no_config());
    assert!(Rc::ptr_eq(&first, &again), "same ambient instance");

    let panicked = catch_unwind(AssertUnwindSafe(|| {
        Station::open(StationOptions {
            profile: Some("prod".to_string()),
            config: ConfigSource::None,
            ..Default::default()
        });
    }))
    .unwrap_err();
    let text = panic_text(&panicked);
    assert!(
        text.contains("station_open_conflict"),
        "conflict code in panic: {}",
        text
    );
    first.close();
    assert!(Station::current().is_none(), "close drops the ambient");
}

#[test]
fn close_warns_on_unmatched_profile_plugin_keys() {
    let station = open_station(station_config(
        r#", "sdk": { "typod-slug": { "base": "http://x" } }"#,
    ));
    station.close();
    let warned = events_of(&station, "station")
        .iter()
        .any(|ev| format!("{:?}", ev.meta).contains("typod-slug"));
    assert!(warned, "typo'd profile key warned at close");
    Station::reset();
}

// --- op events --------------------------------------------------------------

#[test]
fn op_events_correlate_with_http_events() {
    let station = open_station(station_config(""));
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");
    let binding = &bound.binding;

    binding.op_start("CTX1");
    let corr = binding.corr_of("CTX1").expect("corr opened");

    let started = voxgig_station::now_ms();
    binding.done_ok(Some(corr.clone()), "GET", "http://api.test/api/todo", started, 200, 42);
    binding.op_done("CTX1", "todo", "list", "ok");

    let http = events_of(&station, "http");
    let op = events_of(&station, "op");
    assert_eq!(1, http.len());
    assert_eq!(1, op.len());
    assert_eq!(http[0].corr, op[0].corr, "correlated");
    assert_eq!(200, http[0].http.as_ref().unwrap().status);
    assert_eq!("api.test", http[0].http.as_ref().unwrap().host);
    assert_eq!("/api/todo", http[0].http.as_ref().unwrap().path);
    assert_eq!("todo", op[0].op.as_ref().unwrap().entity);
    assert_eq!("list", op[0].op.as_ref().unwrap().op);
    assert_eq!("ok", op[0].op.as_ref().unwrap().outcome);
    assert!(binding.corr_of("CTX1").is_none(), "corr state consumed");
    station.close();
    Station::reset();
}

// --- the shape artifact (design §4.3) ---------------------------------------

// spec/config-shape.json walked up from this crate, the way the corpus
// suite finds spec/station.json.
fn shapefile() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for _step in 0..8 {
        let cand = dir.join("spec").join("config-shape.json");
        if cand.exists() {
            return cand;
        }
        dir = match dir.parent() {
            Some(parent) => parent.to_path_buf(),
            None => break,
        };
    }
    panic!("station: spec not found: config-shape.json");
}

// THE DRIFT GUARD. The shape is DATA, and spec/config-shape.json is the
// copy every port reads - but this crate is published and compiled, so it
// embeds a mirror (src/config-shape.json, written by `make sync-shape`).
// The mirror and the spec must be the same value, or this port is
// validating against a grammar the corpus does not describe.
#[test]
fn config_shape_mirror_matches_the_spec() {
    let text = std::fs::read_to_string(shapefile()).expect("spec shape readable");
    let spec = parse(&text);
    assert_eq!(
        canonical_serialize(&spec),
        canonical_serialize(&config_shape_json()),
        "src/config-shape.json has drifted from spec/config-shape.json - run `make sync-shape`"
    );
}

// The §0 guards on the shape itself, which are cheap and catch an edit
// that would quietly change what the grammar means.
#[test]
fn config_shape_holds_its_invariants() {
    let shape = config_shape_json();
    let profile = jget(&shape, "profiles")
        .and_then(|p| jget(p, "`$CHILD`"))
        .expect("profiles.$CHILD");

    // The two block specs are IDENTICAL: an api block and an sdk block
    // are the same grammar, and a key that reached one but not the other
    // would be a second grammar nobody declared.
    let api = jget(profile, "api").and_then(|a| jget(a, "`$CHILD`")).expect("api block");
    let sdk = jget(profile, "sdk").and_then(|s| jget(s, "`$CHILD`")).expect("sdk block");
    assert_eq!(
        canonical_serialize(api),
        canonical_serialize(sdk),
        "the api and sdk block specs must be identical"
    );

    // MERGE_SENSITIVE names exactly the block defaults that must not be
    // synthesized before the profile merge, and every one of them has a
    // default to be sensitive about.
    assert_eq!(["active"], MERGE_SENSITIVE);
    let defaults = voxgig_station::block_defaults();
    for key in MERGE_SENSITIVE {
        assert!(
            defaults.iter().any(|(name, _)| *name == key),
            "merge-sensitive key {} has no default",
            key
        );
    }
    // And the other direction: every default that is not a CONTAINER is
    // merge-sensitive. A container merges as empty whether or not it was
    // materialized early; a scalar overwrites.
    for (name, val) in defaults.iter() {
        let container = matches!(val, Json::Map(_) | Json::List(_));
        assert!(
            container || MERGE_SENSITIVE.contains(name),
            "scalar block default {} is not listed in MERGE_SENSITIVE",
            name
        );
    }

    // The only `$OPEN` nodes are the three FEATURE-ENTRY nodes: a
    // feature's own options are the SDK's grammar, not station's, and
    // §8.5 checks them against the descriptor instead. Anywhere else, an
    // open map would silently accept a typo.
    let mut open: Vec<String> = Vec::new();
    findopen(&shape, "", &mut open);
    assert_eq!(
        vec![
            "profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`".to_string(),
            "profiles.`$CHILD`.feature.`$CHILD`".to_string(),
            "profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`".to_string(),
        ],
        open
    );
}

fn findopen(node: &Json, path: &str, out: &mut Vec<String>) {
    match node {
        Json::Map(entries) => {
            if matches!(entries.get("`$OPEN`"), Some(Json::Bool(true))) {
                out.push(path.to_string());
            }
            for (key, val) in entries.iter() {
                let kpath = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{}.{}", path, key)
                };
                findopen(val, &kpath, out);
            }
        }
        Json::List(items) => {
            for (at, item) in items.iter().enumerate() {
                findopen(item, &format!("{}.{}", path, at), out);
            }
        }
        _ => {}
    }
}

// Every validate gets a FRESH DEEP COPY: struct's validate consumes the
// spec it walks, so the second call would otherwise validate against a
// spec the first had already eaten.
#[test]
fn config_shape_is_fresh_on_every_call() {
    // TWO CONFIGS TAKING DIFFERENT `$ONE` BRANCHES OF ONE KEY, run in
    // both orders. The contract is that every validate gets a fresh deep
    // copy, because struct's validate CONSUMES the spec it walks - it
    // deletes the satisfied branch as it goes - and a shared spec would
    // let the first run eat `library` so the second had no branch to
    // match. struct's own Rust port also clones internally today, so
    // this is a regression guard on the pipeline rather than a proof of
    // the copy; the copy is in config_shape() because the contract, not
    // one struct build, is what this port holds to.
    let library = parse(r#"{ "station": 1, "profiles": { "default": {
        "sdk": { "solar": { "resolve": "library" } } } } }"#);
    let proxied = parse(r#"{ "station": 1, "profiles": { "default": {
        "sdk": { "solar": { "resolve": "proxy" } } } } }"#);

    assert!(validate_config(&normalize_config(&library)).is_ok(), "first branch");
    assert!(validate_config(&normalize_config(&proxied)).is_ok(), "second branch");
    assert!(validate_config(&normalize_config(&library)).is_ok(), "first branch again");

    // And the shape a caller gets is a value it owns: mutating one has
    // no bearing on the next.
    let _first = config_shape();
    let _second = config_shape();
}

// --- normalize/validate (design §4.2) ---------------------------------------

#[test]
fn normalize_config_leaves_its_input_alone() {
    let raw = parse(r#"{ "station": 1, "profiles": { "default": { "sdk": { "solar": {} } } } }"#);
    let before = canonical_serialize(&raw);
    let out = normalize_config(&raw);
    assert_eq!(before, canonical_serialize(&raw), "the input is untouched");
    assert_ne!(before, canonical_serialize(&out), "the copy carries defaults");
    // A non-map is returned unchanged, for validate to reject by path.
    assert_eq!("7", canonical_serialize(&normalize_config(&Json::Num(7.0))));
}

#[test]
fn validate_config_reports_every_error_at_once() {
    let raw = parse(r#"{ "station": 1, "profiles": { "default": { "sdk": {
        "a": { "bass": 1 }, "b": { "tuba": 2 }, "c": { "oboe": 3 } } } } }"#);
    let err = validate_config(&normalize_config(&raw)).unwrap_err();
    assert_eq!("station_config_invalid", err.code);
    for want in ["sdk.a: bass", "sdk.b: tuba", "sdk.c: oboe"] {
        assert!(err.msg.contains(want), "every error at once: {}", err.msg);
    }
}

// --- the loader that is not here (design §6.3, §5.4) ------------------------

#[test]
fn check_package_takes_only_module_names() {
    assert_eq!("@acme/sdk", check_package("acme", "@acme/sdk").unwrap());
    for bad in [
        "",
        "./local",
        "/abs/path",
        "~/home",
        "https://example.com/sdk",
        "win\\path",
        // The SEGMENT check, which the prefix checks do not imply: this
        // starts with neither `.` nor `/` and would resolve OUT of the
        // named dependency.
        "pkg/../../escape",
    ] {
        let err = check_package("acme", bad).unwrap_err();
        assert_eq!("station_sdk_load", err.code, "rejected: {:?}", bad);
    }
}

#[test]
fn camelify_splits_on_non_alphanumerics() {
    assert_eq!("StripeEu", camelify("stripe-eu"));
    assert_eq!("VoxgigSolardemo", camelify("voxgig_solardemo"));
    assert_eq!("Pad", camelify("pad"));
}

// --- the factory table (design §6.2) ----------------------------------------

// A generated crate's constructor, as station calls it. It stands in for
// the generated adapter: it BINDS, with the station feature options
// station built - which is where the instance name rides (§7.5).
fn fake_factory() -> Factory {
    Factory {
        construct: Rc::new(|options: &Json| {
            let client: Rc<dyn Any> = Rc::new(RefCell::new(options.clone()));
            let fopts = jget(options, "feature")
                .and_then(|f| jget(f, "station"))
                .cloned()
                .unwrap_or(Json::Null);
            let mut bspec = spec(client.clone(), &["test", "station"]);
            bspec.feature_opts = fopts;
            bind(bspec);
            client
        }),
        config: config(),
    }
}

#[test]
fn provide_is_idempotent_and_conflicts_loudly() {
    reset_factories();
    let factory = fake_factory();
    let first = provide("taskpad", factory.clone()).expect("provided");
    let again = provide("taskpad", factory).expect("same pair is a no-op");
    assert!(Rc::ptr_eq(&first, &again), "one entry, not two");
    assert_eq!(vec!["taskpad".to_string()], provided());

    // The descriptor is normalized AT PROVIDE TIME, so check() can read
    // the feature schema with nothing constructed.
    assert_eq!("taskpad", jstr(&first.descriptor, "slug"));

    let err = match provide("taskpad", fake_factory()) {
        Err(err) => err,
        Ok(_) => panic!("a different factory must conflict"),
    };
    assert_eq!("station_factory_conflict", err.code);
    reset_factories();
}

#[test]
fn sdk_caches_create_autotags_and_the_alias_carries_the_block() {
    Station::reset();
    reset_factories();
    provide("taskpad", fake_factory()).expect("provided");
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": { "base": "http://declared", "secret": "declared.name",
             "policy": { "hosts": ["api.test"] } } }"#,
    ));

    let one = station.sdk("taskpad").expect("built");
    let two = station.sdk("taskpad").expect("cached");
    assert!(Rc::ptr_eq(&one, &two), "sdk() caches by name");

    // The construction bound: the registry is keyed by the INSTANCE.
    let live: Vec<String> = station.plugins().iter().map(|p| p.name.clone()).collect();
    assert_eq!(vec!["taskpad".to_string()], live);
    assert_eq!(
        "declared.name",
        station.plugins()[0].secretname,
        "the profile's secret name is stored on the entry"
    );

    // create() is UNCACHED and takes the lowest free integer tag.
    let extra = station.create("taskpad", None).expect("created");
    assert!(!Rc::ptr_eq(&one, &extra), "create() is uncached");
    let mut live: Vec<String> = station.plugins().iter().map(|p| p.name.clone()).collect();
    live.sort();
    assert_eq!(
        vec!["taskpad".to_string(), "taskpad$1".to_string()],
        live,
        "plugins() is exhaustive - an auto-tagged entry is an ordinary one"
    );

    // THE ALIAS CARRIES THE BLOCK, not just the secret: the auto-tagged
    // client keeps its declared instance's hosts allowlist and base.
    assert_eq!("taskpad", station.declared_ref("taskpad$1"));
    assert_eq!(
        "http://declared",
        jstr(&station.block_for("taskpad$1"), "base")
    );
    assert_eq!(
        "declared.name",
        station
            .plugins()
            .iter()
            .find(|p| "taskpad$1" == p.name)
            .expect("tagged entry")
            .secretname,
        "the derived name follows the DECLARED ref, not the assigned tag"
    );

    station.close();
    Station::reset();
    reset_factories();
}

#[test]
fn build_refuses_unknown_inactive_and_factoryless_instances() {
    Station::reset();
    reset_factories();
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": {}, "off": { "active": false } }"#,
    ));

    let err = station.sdk("nope").unwrap_err();
    assert_eq!("station_no_instance", err.code);
    assert!(err.msg.contains("declared: [off, taskpad]"), "{}", err.msg);

    let err = station.sdk("off").unwrap_err();
    assert_eq!("station_instance_inactive", err.code);

    // No factory: the message names the remedy THIS port offers, and
    // says plainly that `package` is not honoured here (§5.4 item 3).
    let err = station.sdk("taskpad").unwrap_err();
    assert_eq!("station_no_factory", err.code);
    assert!(err.msg.contains("Station::provide"), "{}", err.msg);
    assert!(err.msg.contains("`package` is not honoured"), "{}", err.msg);

    station.close();
    Station::reset();
}

// §5.4 item 2: `package` stays in the grammar and is ignored HERE, with
// one warning event per api at open.
#[test]
fn a_configured_package_warns_once_at_open() {
    Station::reset();
    let station = open_station(station_config(
        r#", "api": { "taskpad": { "package": "@acme/taskpad-sdk" } },
            "sdk": { "taskpad": {}, "taskpad$eu": {} }"#,
    ));
    let warns: Vec<StationEvent> = station
        .events()
        .into_iter()
        .filter(|ev| format!("{:?}", ev.meta).contains("`package` is not honoured"))
        .collect();
    assert_eq!(1, warns.len(), "one event per api, at open, once");
    assert_eq!(Some("taskpad".to_string()), warns[0].api);
    station.close();
    Station::reset();
}

// --- features_of (design §8.7) ----------------------------------------------

#[test]
fn features_of_merges_levels_and_records_provenance() {
    Station::reset();
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(
            r#"{ "station": 1, "profiles": { "default": {
                 "feature": { "retry": { "max": 1, "wait": 100 } },
                 "api": { "taskpad": { "feature": { "retry": { "max": 2 } } } },
                 "sdk": { "taskpad$test": { "feature": { "retry": { "max": 3 } } } } } } }"#,
        )),
        ..Default::default()
    });

    let set = station.features_of("taskpad$test").expect("resolved");
    let retry = jget(&set.merged, "retry").expect("retry");
    assert_eq!("3", canonical_serialize(jget(retry, "max").unwrap()));
    assert_eq!("100", canonical_serialize(jget(retry, "wait").unwrap()));
    assert_eq!("default.sdk", set.from["retry"]["max"], "last writer wins");
    assert_eq!("default.feature", set.from["retry"]["wait"]);

    // The implicit `station` row is for ORDERING ONLY: it is in the
    // reported order and never in the merge.
    assert_eq!(vec!["retry".to_string(), "station".to_string()], set.ordered);
    assert!(jget(&set.merged, "station").is_none(), "station is not merged");
    Station::reset();
}

#[test]
fn features_of_composes_the_policy_budget_into_ratelimit() {
    Station::reset();
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(
            r#"{ "station": 1, "profiles": { "default": { "sdk": { "taskpad": {
                 "feature": { "ratelimit": { "spread": true } },
                 "policy": { "budget": { "rps": 5, "concurrency": 2 } } } } } } }"#,
        )),
        ..Default::default()
    });

    let set = station.features_of("taskpad").expect("resolved");
    let rl = jget(&set.merged, "ratelimit").expect("ratelimit");
    assert_eq!("true", canonical_serialize(jget(rl, "active").unwrap()));
    assert_eq!("5", canonical_serialize(jget(rl, "rate").unwrap()));
    assert_eq!("2", canonical_serialize(jget(rl, "burst").unwrap()));
    assert_eq!(
        "true",
        canonical_serialize(jget(rl, "spread").unwrap()),
        "other tuning keys survive beside the policy"
    );
    assert_eq!("policy.budget", set.from["ratelimit"]["rate"]);
    assert_eq!("policy.budget", set.from["ratelimit"]["burst"]);
    Station::reset();
}

// --- §8.5, the descriptor-derived checker -----------------------------------

#[test]
fn check_features_catches_unknown_features_and_options() {
    let sdkconfig = parse(
        r#"{ "main": { "name": "Pad", "slug": "pad" },
             "feature": { "retry": { "options": { "max": 1, "spread": true } } } }"#,
    );
    let (descriptor, _warnings) = normalize_descriptor(&sdkconfig, &Json::Null);

    // The descriptor now CARRIES the option schema (§8.5).
    let features = jget(&descriptor, "features").expect("features");
    let row = match features {
        Json::List(items) => items[0].clone(),
        _ => panic!("features is a list"),
    };
    assert!(jget(&row, "options").is_some(), "options carried");

    let merged = parse(
        r#"{ "nope": {}, "retry": { "active": true, "max": "three", "retires": 5 } }"#,
    );
    let faults = check_features(&merged, &descriptor);
    let codes: Vec<String> = faults.iter().map(|f| f.code.clone()).collect();
    assert_eq!(
        vec![
            "station_feature_unknown".to_string(),
            "station_feature_option".to_string(),
            "station_feature_option".to_string()
        ],
        codes,
        "sorted by feature, then by option key"
    );
    assert!(faults[0].message.contains("it declares [retry]"), "{}", faults[0].message);
    assert!(
        faults[1].message.contains("expects number, but found string"),
        "{}",
        faults[1].message
    );
    assert!(
        faults[2].message.contains("declares no option \"retires\""),
        "{}",
        faults[2].message
    );
    // `active` and `order` are reserved: never options, never faults.
    assert!(faults.iter().all(|f| f.key.as_deref() != Some("active")));
}

// The §8.5 pass runs in build(), not only in check() - so a production
// sdk() cannot silently ignore a typo'd option.
#[test]
fn build_runs_the_feature_check() {
    Station::reset();
    reset_factories();
    provide("taskpad", fake_factory()).expect("provided");
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": { "feature": { "nosuch": { "active": true } } } }"#,
    ));
    let err = station.sdk("taskpad").unwrap_err();
    assert_eq!("station_feature_unknown", err.code);
    assert!(err.msg.contains("no feature \"nosuch\""), "{}", err.msg);
    station.close();
    Station::reset();
    reset_factories();
}

// --- instances(), check(), warm() -------------------------------------------

#[test]
fn instances_reports_declared_and_check_constructs_the_active() {
    Station::reset();
    reset_factories();
    provide("taskpad", fake_factory()).expect("provided");
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": {}, "taskpad$off": { "active": false } }"#,
    ));

    let rows = station.instances();
    assert_eq!(2, rows.len(), "one row per DECLARED instance");
    assert_eq!("taskpad", rows[0].name);
    assert!(rows[0].active && !rows[0].live, "declared, not yet live");
    assert!(!rows[1].active, "`active: false` is visible, not hidden");

    let result = station.check();
    assert_eq!(vec!["taskpad".to_string()], result.ok);
    assert!(result.failed.is_empty(), "{:?}", result.failed);
    assert!(station.instances()[0].live, "check() constructed it");

    station.close();
    Station::reset();
    reset_factories();
}

#[test]
fn check_turns_a_deferred_failure_into_one_report() {
    Station::reset();
    reset_factories();
    let station = open_station(station_config(r#", "sdk": { "taskpad": {} }"#));
    let result = station.check();
    assert!(result.ok.is_empty());
    assert_eq!(1, result.failed.len());
    assert_eq!("taskpad", result.failed[0].name);
    assert_eq!("station_no_factory", result.failed[0].code);
    station.close();
    Station::reset();
}

#[test]
fn warm_resolves_declared_names_and_misses_the_rest() {
    Station::reset();
    let station = open_station(parse(
        r#"{ "station": 1, "profiles": { "default": {
             "secrets": { "providers": [ { "kind": "memory", "values": {
               "SHARED_APIKEY": "one-value" } } ] },
             "api": { "taskpad": { "secret": "shared.apikey" } },
             "sdk": { "taskpad": {}, "taskpad$eu": {},
                      "taskpad$off": { "active": false } } } } }"#,
    ));

    // Two instances share one api-level `secret`, so they resolve as ONE
    // name; the inactive one is not warmed by default.
    let warm = station.warm(None);
    assert_eq!(
        vec!["taskpad".to_string(), "taskpad$eu".to_string()],
        warm.warmed
    );
    assert!(warm.missed.is_empty(), "{:?}", warm.missed);

    // An explicit name is an explicit request - inactive included.
    let warm = station.warm(Some(&["taskpad$off".to_string()]));
    assert_eq!(vec!["taskpad$off".to_string()], warm.warmed);

    // A NAME NOBODY DECLARED IS A MISS, not a lookup: no derived name,
    // no provider call, no `warmed` off a shared api-level credential.
    let warm = station.warm(Some(&["taskpad$prodd".to_string()]));
    assert!(warm.warmed.is_empty());
    assert_eq!(vec!["taskpad$prodd".to_string()], warm.missed);

    station.close();
    Station::reset();
}

// --- §6.3's review boundary -------------------------------------------------

#[test]
fn repo_scoped_reads_the_explicit_option_first() {
    Station::reset();
    // An in-code config is repo-scoped by construction...
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(r#"{ "station": 1 }"#)),
        ..Default::default()
    });
    assert!(station.repo_scoped());

    // ...and the EXPLICIT option still wins, which is the precedence bug
    // this order exists to avoid.
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(r#"{ "station": 1 }"#)),
        repo_scoped: Some(false),
        ..Default::default()
    });
    assert!(!station.repo_scoped());

    // With no file anywhere, the scope is 'none' - which is not 'user',
    // so a config that does not exist does not narrow anything.
    let empty = std::env::temp_dir().join(format!("station-scope-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    std::fs::create_dir_all(empty.join(".git")).unwrap();
    assert_eq!("none", config_scope(Some(&empty)));
    std::fs::write(empty.join("station.json"), "{ \"station\": 1 }").unwrap();
    assert_eq!("repo", config_scope(Some(&empty)));
    std::fs::remove_dir_all(&empty).ok();
    Station::reset();
}

// A station.json that will not parse names the FILE, rather than letting
// a parser error escape open().
#[test]
fn a_malformed_config_file_names_itself() {
    let dir = std::env::temp_dir().join(format!("station-bad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    std::fs::write(dir.join("station.json"), "{ nope").unwrap();

    let err = voxgig_station::load_config(Some(&dir)).unwrap_err();
    assert_eq!("station_config_invalid", err.code);
    assert!(err.msg.contains("station.json"), "{}", err.msg);
    assert!(err.msg.contains("not valid JSON"), "{}", err.msg);

    std::fs::remove_dir_all(&dir).ok();
}

// --- the fleet view (design §8.7) -------------------------------------------

#[test]
fn features_view_narrows_rows_to_the_named_feature() {
    Station::reset();
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(
            r#"{ "station": 1, "profiles": { "default": { "sdk": {
                 "pad": { "feature": { "debug": { "level": 2 }, "retry": {} } },
                 "pad$eu": { "feature": { "retry": {} } },
                 "other": { "feature": { "debug": { "level": 9 } } } } } } }"#,
        )),
        ..Default::default()
    });

    // No filter: one row per declared instance.
    assert_eq!(3, station.features(None).expect("all").len());

    // The string shorthand is loose - "this instance or this api".
    let rows = station
        .features(Some(&voxgig_station::loose_filter("pad")))
        .expect("loose");
    let names: Vec<String> = rows.iter().map(|r| r.instance.clone()).collect();
    assert_eq!(vec!["pad".to_string(), "pad$eu".to_string()], names);

    // A `feature` filter narrows the ROWS, and each row's contents:
    // "where is debug on, and with what".
    let rows = station
        .features(Some(&voxgig_station::FeatureFilter {
            feature: Some("debug".to_string()),
            ..Default::default()
        }))
        .expect("by feature");
    let names: Vec<String> = rows.iter().map(|r| r.instance.clone()).collect();
    assert_eq!(vec!["other".to_string(), "pad".to_string()], names);
    assert_eq!(vec!["debug".to_string()], rows[1].ordered);
    assert!(
        jget(&rows[1].merged, "retry").is_none(),
        "the row is narrowed to the named feature"
    );
    assert_eq!("default.sdk", rows[1].from["debug"]["level"]);
    Station::reset();
}

// --- policy at the binding seam (design §16) --------------------------------

#[test]
fn binding_hands_back_the_policy_allowlist() {
    Station::reset();
    let station = open_station(station_config(
        r#", "sdk": { "taskpad": { "policy": { "allow": {
             "op": ["list", "load"], "method": ["GET"] } } } }"#,
    ));
    let client: Rc<dyn Any> = Rc::new(());
    let bound = bind(spec(client, &["test", "station"])).expect("bound");

    // The SDK's own option form is a comma-separated string, and this is
    // ENFORCEMENT: the adapter applies it OVER options.allow.
    let allow = bound.allow.expect("allow");
    assert_eq!("list,load", jstr(&allow, "op"));
    assert_eq!("GET", jstr(&allow, "method"));

    station.close();
    Station::reset();
}

// A tagged instance reads ITS OWN block, not the wider api-level one -
// the §6.4 rule that kept a declared allowlist from being lost.
#[test]
fn block_for_prefers_the_declared_instance_over_the_api() {
    Station::reset();
    let station = Station::new(StationOptions {
        config: ConfigSource::Value(parse(
            r#"{ "station": 1, "profiles": { "default": {
                 "api": { "pad": { "base": "http://api", "policy": { "hosts": ["wide.test"] } } },
                 "sdk": { "pad$eu": { "policy": { "hosts": ["eu.test"] } } } } } }"#,
        )),
        ..Default::default()
    });

    // Declared: its own block, with the api defaults merged under it.
    let block = station.block_for("pad$eu");
    assert_eq!("http://api", jstr(&block, "base"));
    assert_eq!(
        "[\"eu.test\"]",
        canonical_serialize(jget(jget(&block, "policy").unwrap(), "hosts").unwrap())
    );

    // Never declared - an imperative instance still gets the api block.
    let block = station.block_for("pad$adhoc");
    assert_eq!("http://api", jstr(&block, "base"));
    assert_eq!(
        "[\"wide.test\"]",
        canonical_serialize(jget(jget(&block, "policy").unwrap(), "hosts").unwrap())
    );
    Station::reset();
}
