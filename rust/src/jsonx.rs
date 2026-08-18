//! Small helpers over the shared JSON value model.
//!
//! Station's value model IS sekreto's `Json` (re-exported from lib.rs):
//! one dependency, one value type, no second JSON library - the modem
//! principle (design §10). `BTreeMap` keys iterate in bytewise order,
//! which is exactly the canonical-serialization order (§4).

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use voxgig_sekreto::Json;

/// A map entry, or None.
pub fn jget<'a>(val: &'a Json, key: &str) -> Option<&'a Json> {
    match val {
        Json::Map(entries) => entries.get(key),
        _ => None,
    }
}

/// A string entry ('' when absent or not a string).
pub fn jstr(val: &Json, key: &str) -> String {
    match jget(val, key) {
        Some(Json::Str(text)) => text.clone(),
        _ => String::new(),
    }
}

/// A bool entry (None when absent or not a bool).
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

/// Build a map value.
pub fn jobj(entries: Vec<(&str, Json)>) -> Json {
    let mut out = BTreeMap::new();
    for (key, val) in entries {
        out.insert(key.to_string(), val);
    }
    Json::Map(out)
}

/// Build a string value.
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
