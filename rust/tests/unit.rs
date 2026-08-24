// RUN: make test  (cargo test, after `make vendor`)
//
// Focused unit tests for the pieces the corpus cannot see: the event
// ring/tap, the broker's miss-vs-error split and floorless scrub, the
// bind() guards (wrap order, second arrival, bound twice, inert without
// an open station), the per-request prepare() decisions (require,
// hosts policy + manual redirects, injection, mock non-injection), and
// the station.json lookup walk. Each test thread gets its own ambient
// instance (thread-local), so tests stay isolated without a lock.

use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

use voxgig_station::{
    bind, find_config_file, jobj, jtext, placeholder_for, BindSpec, ConfigSource, EventBuffer,
    Json, SecretBroker, Station, StationEvent, StationOptions,
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
