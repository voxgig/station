
use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use voxgig_sekreto::voxgig_plugin::value::Value as Json;

/// This value as a string, the way the canonical port's String() renders
/// it: strings verbatim, everything else as compact JSON. sekreto's own
/// `Json` had this as a method; plugin's `Value`, which replaced it
/// (sekreto 43eb579), does not - `json()` is the only renderer, and it
/// quotes strings.
pub fn jtextof(val: &Json) -> String {
    match val {
        Json::Str(text) => text.clone(),
        other => other.json(),
    }
}

pub fn jget<'a>(val: &'a Json, key: &str) -> Option<&'a Json> {
    match val {
        Json::Map(entries) => entries.get(key),
        _ => None,
    }
}

pub fn jstr(val: &Json, key: &str) -> String {
    match jget(val, key) {
        Some(Json::Str(text)) => text.clone(),
        _ => String::new(),
    }
}

pub fn jbool(val: &Json, key: &str) -> Option<bool> {
    match jget(val, key) {
        Some(Json::Bool(flag)) => Some(*flag),
        _ => None,
    }
}

/// A map entry's entries (None when absent or not a map).
pub fn jmap<'a>(val: &'a Json, key: &str) -> Option<&'a BTreeMap<String, Json>> {
    match jget(val, key) {
        Some(Json::Map(entries)) => Some(entries),
        _ => None,
    }
}

/// A list entry's items (None when absent or not a list).
pub fn jlist<'a>(val: &'a Json, key: &str) -> Option<&'a Vec<Json>> {
    match jget(val, key) {
        Some(Json::List(items)) => Some(items),
        _ => None,
    }
}

pub fn jobj(entries: Vec<(&str, Json)>) -> Json {
    let mut out = BTreeMap::new();
    for (key, val) in entries {
        out.insert(key.to_string(), val);
    }
    Json::Map(out)
}

pub fn jtext(text: impl Into<String>) -> Json {
    Json::Str(text.into())
}

/// Wall-clock milliseconds since the epoch (the `t` of every event).
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
