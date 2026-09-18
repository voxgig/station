
use std::collections::BTreeMap;

use voxgig_sekreto::validname;
use voxgig_sekreto::voxgig_plugin::value::Value as Json;
use voxgig_struct::{clone as structclone, validate, InjectDef, Value};

use crate::descriptor::{canonical_serialize, envtoken};
use crate::error::StationError;
use crate::jsonx::{jget, jmap};


/// The profile-level containers. Safe to materialize early either way:
/// they are containers, and a missing one merges as empty regardless.
///
/// Built per call, so a caller cannot alias a shared default into a
/// config.
pub fn profile_defaults() -> Vec<(&'static str, Json)> {
    vec![
        (
            "secrets",
            crate::jsonx::jobj(vec![(
                "providers",
                Json::List(vec![crate::jsonx::jobj(vec![(
                    "kind",
                    Json::Str("env".to_string()),
                )])]),
            )]),
        ),
        ("api", Json::Map(BTreeMap::new())),
        ("sdk", Json::Map(BTreeMap::new())),
        ("feature", Json::Map(BTreeMap::new())),
    ]
}

pub fn block_defaults() -> Vec<(&'static str, Json)> {
    vec![
        ("active", Json::Bool(true)),
        ("feature", Json::Map(BTreeMap::new())),
    ]
}

/// The one block key carrying the timing rule. Named rather than
/// inferred, so a reader does not have to work out which of the two it
/// is, and so a port can assert it.
pub const MERGE_SENSITIVE: [&str; 1] = ["active"];

// ---------------------------------------------------------------------
// normalize_config
// ---------------------------------------------------------------------

pub fn normalize_config(raw: &Json) -> Json {
    let rawmap = match raw {
        Json::Map(entries) => entries,
        other => return other.clone(),
    };

    let mut out = rawmap.clone();

    out.entry("station".to_string())
        .or_insert_with(|| Json::Num(1.0));
    out.entry("profiles".to_string())
        .or_insert_with(|| Json::Map(BTreeMap::new()));

    let rawprofiles = match out.get("profiles") {
        Some(Json::Map(entries)) => entries.clone(),
        // Present but not a map: leave it for validate to reject by path.
        _ => return Json::Map(out),
    };

    let mut profiles: BTreeMap<String, Json> = BTreeMap::new();
    for (pname, praw) in rawprofiles.iter() {
        let p = match praw {
            Json::Map(entries) => entries,
            other => {
                profiles.insert(pname.clone(), other.clone());
                continue;
            }
        };
        let mut prof = p.clone();

        for (key, val) in profile_defaults() {
            prof.entry(key.to_string()).or_insert(val);
        }

        // A `secrets` written without `providers` still gets the chain.
        if let Some(Json::Map(secrets)) = prof.get("secrets") {
            if !secrets.contains_key("providers") {
                let mut with = secrets.clone();
                with.insert(
                    "providers".to_string(),
                    Json::List(vec![crate::jsonx::jobj(vec![(
                        "kind",
                        Json::Str("env".to_string()),
                    )])]),
                );
                prof.insert("secrets".to_string(), Json::Map(with));
            }
        }

        if let Some(feature) = prof.get("feature") {
            let normed = normfeatures(feature);
            prof.insert("feature".to_string(), normed);
        }

        for bkey in ["api", "sdk"] {
            let rawblocks = match prof.get(bkey) {
                Some(Json::Map(entries)) => entries.clone(),
                _ => continue,
            };
            let mut blocks: BTreeMap<String, Json> = BTreeMap::new();
            for (reference, braw) in rawblocks.iter() {
                let b = match braw {
                    Json::Map(entries) => entries,
                    other => {
                        blocks.insert(reference.clone(), other.clone());
                        continue;
                    }
                };
                let mut block = b.clone();
                for (key, val) in block_defaults() {
                    block.entry(key.to_string()).or_insert(val);
                }
                if let Some(feature) = block.get("feature") {
                    let normed = normfeatures(feature);
                    block.insert("feature".to_string(), normed);
                }
                blocks.insert(reference.clone(), Json::Map(block));
            }
            prof.insert(bkey.to_string(), Json::Map(blocks));
        }

        profiles.insert(pname.clone(), Json::Map(prof));
    }

    out.insert("profiles".to_string(), Json::Map(profiles));
    Json::Map(out)
}

fn normfeatures(f: &Json) -> Json {
    let entries = match f {
        Json::Map(entries) => entries,
        other => return other.clone(),
    };
    let mut out: BTreeMap<String, Json> = BTreeMap::new();
    for (name, entry) in entries.iter() {
        match entry {
            Json::Map(fields) if !fields.contains_key("active") => {
                let mut with = fields.clone();
                with.insert("active".to_string(), Json::Bool(true));
                out.insert(name.clone(), Json::Map(with));
            }
            other => {
                out.insert(name.clone(), other.clone());
            }
        }
    }
    Json::Map(out)
}

// ---------------------------------------------------------------------
// validate_config
// ---------------------------------------------------------------------

const CONFIG_SHAPE_JSON: &str = include_str!("config-shape.json");

pub fn config_shape() -> Value {
    thread_local! {
        static PARSED: Value = parse_shape();
    }
    PARSED.with(structclone)
}

fn parse_shape() -> Value {
    let parsed = voxgig_sekreto::voxgig_plugin::value::parse(CONFIG_SHAPE_JSON)
        .expect("station: the embedded config shape is not valid JSON");
    json_to_value(&parsed)
}

/// The shape as station's own value model, for the port-local guard
/// tests (the drift check, and §0's optional shape assertions).
pub fn config_shape_json() -> Json {
    voxgig_sekreto::voxgig_plugin::value::parse(CONFIG_SHAPE_JSON)
        .expect("station: the embedded config shape is not valid JSON")
}

/// Credential-shaped keys (§5.2). `secret` is here AND is the one exempt
/// key - see `secretvalue` below; a blanket deny would reject the very
/// mechanism that keeps values out of the file.
const CREDENTIAL_KEYS: [&str; 8] = [
    "apikey",
    "auth",
    "authorization",
    "token",
    "secret",
    "password",
    "credential",
    "bearer",
];

const CREDENTIAL_SUFFIX: [&str; 4] = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"];

const RUN_BOUND: usize = 24;

fn unbroken_run(text: &str) -> bool {
    let mut run = 0usize;
    for head in text.chars() {
        if head.is_ascii_alphanumeric() {
            run += 1;
            if RUN_BOUND <= run {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

pub fn validate_config(normalized: &Json) -> Result<Json, StationError> {
    let errsval = Value::empty_list();
    let def = InjectDef {
        errs: Some(errsval.clone()),
        ..Default::default()
    };
    let _ = validate(&json_to_value(normalized), &config_shape(), Some(&def));

    let mut errs: Vec<String> = Vec::new();
    if let Value::List(items) = &errsval {
        for one in items.borrow().iter() {
            match one {
                Value::Str(text) => errs.push(text.clone()),
                other => errs.push(canonical_serialize(&value_to_json(other))),
            }
        }
    }

    let scanned = scan_config(normalized);

    if !errs.is_empty() || !scanned.invalid.is_empty() {
        let mut all = errs;
        all.extend(scanned.invalid);
        return Err(StationError::new(
            "station_config_invalid",
            all.join("; ") + &renamehint(normalized),
        ));
    }
    if !scanned.reserved.is_empty() {
        return Err(StationError::new(
            "station_feature_reserved",
            scanned.reserved.join("; "),
        ));
    }
    if !scanned.secrets.is_empty() {
        return Err(StationError::new(
            "station_config_secret",
            scanned.secrets.join("; "),
        ));
    }
    Ok(normalized.clone())
}

fn renamehint(cfg: &Json) -> String {
    let empty = BTreeMap::new();
    let profiles = jmap(cfg, "profiles").unwrap_or(&empty);
    let hit: Vec<String> = profiles
        .iter()
        .filter(|(_, prof)| matches!(prof, Json::Map(entries) if entries.contains_key("plugin")))
        .map(|(pname, _)| format!("profiles.{}", pname))
        .collect();
    if hit.is_empty() {
        return String::new();
    }
    format!(
        "; rename `plugin` to `sdk` in {} - the keys are unchanged, an \
         untagged ref IS an api slug (§3.4)",
        hit.join(", ")
    )
}

/// they are COLLECTED rather than raised, because `validate_config` owns
#[derive(Default)]
struct Scanned {
    secrets: Vec<String>,
    reserved: Vec<String>,
    invalid: Vec<String>,
}

/// data. Everything else is closed by construction and needs no scan -
fn scan_config(cfg: &Json) -> Scanned {
    let mut out = Scanned::default();

    let empty = BTreeMap::new();
    let profiles = jmap(cfg, "profiles").unwrap_or(&empty);
    for (pname, prof) in profiles.iter() {
        if !matches!(prof, Json::Map(_)) {
            continue;
        }
        let ppath = format!("profiles.{}", pname);

        checkconfigfeatures(
            jget(prof, "feature"),
            &format!("{}.feature", ppath),
            &mut out,
        );

        for bkey in ["api", "sdk"] {
            let blocks = match jmap(prof, bkey) {
                Some(entries) => entries,
                None => continue,
            };
            for (reference, block) in blocks.iter() {
                if !matches!(block, Json::Map(_)) {
                    continue;
                }
                let bpath = format!("{}.{}.{}", ppath, bkey, reference);

                if let Some(secret) = jget(block, "secret") {
                    secretvalue(secret, &format!("{}.secret", bpath), &mut out.secrets);
                }

                scan(
                    jget(block, "options"),
                    &format!("{}.options", bpath),
                    &mut out,
                );
                checkconfigfeatures(
                    jget(block, "feature"),
                    &format!("{}.feature", bpath),
                    &mut out,
                );

                // §4.4's explicit checks, applied where the shape cannot
                checkpolicy(
                    jget(block, "policy"),
                    &format!("{}.policy", bpath),
                    &mut out.invalid,
                );
            }
        }
    }

    out
}

/// A feature map at any level. `station` is reserved: station composes
/// its own wrap and a config that reconfigures it is asking for a state
/// the ordering rules cannot express (§8.4) - and a config file that can
/// switch off the component reading it is not a surface, it is a trap.
fn checkconfigfeatures(f: Option<&Json>, path: &str, out: &mut Scanned) {
    let entries = match f {
        Some(Json::Map(entries)) => entries,
        _ => return,
    };
    for (name, entry) in entries.iter() {
        let fpath = format!("{}.{}", path, name);
        if "station" == name {
            out.reserved.push(format!(
                "{}.station is reserved: station composes its own wrap and it \
                 cannot be configured from station.json",
                path
            ));
        }
        if let Some(Json::Map(order)) = jget(entry, "order") {
            firstelement(
                order.get("before"),
                &format!("{}.order.before", fpath),
                &mut out.invalid,
            );
            firstelement(
                order.get("after"),
                &format!("{}.order.after", fpath),
                &mut out.invalid,
            );
        }
        scan(Some(entry), &fpath, out);
    }
}

const BUDGET_KEYS: [&str; 2] = ["concurrency", "rps"];

fn checkpolicy(policy: Option<&Json>, path: &str, invalid: &mut Vec<String>) {
    let entries = match policy {
        Some(Json::Map(entries)) => entries,
        _ => return,
    };

    firstelement(entries.get("hosts"), &format!("{}.hosts", path), invalid);

    if let Some(Json::Map(allow)) = entries.get("allow") {
        firstelement(allow.get("op"), &format!("{}.allow.op", path), invalid);
        firstelement(
            allow.get("method"),
            &format!("{}.allow.method", path),
            invalid,
        );
    }

    if let Some(Json::Map(budget)) = entries.get("budget") {
        let unknown: Vec<String> = budget
            .keys()
            .filter(|key| !BUDGET_KEYS.contains(&key.as_str()))
            .cloned()
            .collect();
        if !unknown.is_empty() {
            invalid.push(format!(
                "Unexpected keys at field {}.budget: {}",
                path,
                unknown.join(", ")
            ));
        }
    }
}

/// §4.4: `$CHILD` in LIST mode DOES NOT VALIDATE ELEMENT 0. Verified:
/// `["a", 1]` fails at index 1, `[1]` passes, at any list length. An
/// per-feature `order.before` / `order.after`. Applied where the shape
/// cannot reach, raising the same code the shape would, and pinned in the
fn firstelement(list: Option<&Json>, path: &str, invalid: &mut Vec<String>) {
    let items = match list {
        Some(Json::List(items)) if !items.is_empty() => items,
        _ => return,
    };
    if matches!(items[0], Json::Str(_)) {
        return;
    }
    invalid.push(format!(
        "Expected field {}.0 to be string, but found {}: {}",
        path,
        shapekind(&items[0]),
        canonical_serialize(&items[0])
    ));
}

/// Recursive over EVERY nested map and list, not just the top level - a
/// credential one level down is the case a top-level scan misses
/// (`config#options-scan-is-recursive` pins `options.deep.list.0.apikey`).
fn scan(node: Option<&Json>, path: &str, out: &mut Scanned) {
    let node = match node {
        Some(node) => node,
        None => return,
    };
    match node {
        Json::List(items) => {
            for (at, item) in items.iter().enumerate() {
                scan(Some(item), &format!("{}.{}", path, at), out);
            }
        }
        Json::Str(text) => userinfo(text, path, &mut out.secrets),
        Json::Map(entries) => {
            for (key, val) in entries.iter() {
                let kpath = format!("{}.{}", path, key);

                // the drift this design exists to prevent.
                if "feature" == key {
                    out.reserved.push(format!(
                        "{} is reserved: configure features under the block's \
                         own `feature` key, not through `options`",
                        kpath
                    ));
                    continue;
                }

                if "secret" == key.to_lowercase() {
                    secretvalue(val, &kpath, &mut out.secrets);
                    continue;
                }

                if credentialkey(key) {
                    out.secrets.push(format!(
                        "{} is a credential-shaped key: station.json holds \
                         secret NAMES, never values (§5.2)",
                        kpath
                    ));
                    continue;
                }

                scan(Some(val), &kpath, out);
            }
        }
        _ => {}
    }
}

fn credentialkey(key: &str) -> bool {
    let low: String = key
        .to_lowercase()
        .chars()
        .filter(|head| head.is_ascii_lowercase() || head.is_ascii_digit())
        .collect();
    if CREDENTIAL_KEYS.contains(&low.as_str()) {
        return true;
    }
    let token = envtoken(key);
    CREDENTIAL_SUFFIX
        .iter()
        .any(|suffix| token.ends_with(suffix))
}

/// A `secret`-named key holds a NAME, and that exemption is not a
/// loophole - it is the whole design, since a blanket deny would reject
/// precisely so a port cannot implement only the first and inherit the
fn secretvalue(val: &Json, path: &str, secrets: &mut Vec<String>) {
    let text = match val {
        Json::Str(text) => text,
        other => {
            secrets.push(format!(
                "{} must be a secret name (a string), but found {}",
                path,
                shapekind(other)
            ));
            return;
        }
    };
    if !validname(text) {
        secrets.push(format!(
            "{} is not a valid sekreto name, so it cannot be a name and must \
             not be a value: {}",
            path,
            canonical_serialize(val)
        ));
        return;
    }
    if unbroken_run(text) {
        secrets.push(format!(
            "{} contains an unbroken alphanumeric run of {} or more \
             characters, which is not a name anybody writes",
            path, RUN_BOUND
        ));
    }
}

/// One rule about VALUES rather than keys, because the `proxy` feature
/// makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
fn userinfo(val: &str, path: &str, secrets: &mut Vec<String>) {
    if !has_scheme(val) {
        return;
    }
    let rest = match val.find("://") {
        Some(at) => &val[at + 3..],
        None => return,
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    match authority.rfind('@') {
        Some(at) if 0 < at => {
            secrets.push(format!(
                "{} is a URL carrying userinfo, which puts a credential in the \
                 config file; use the proxy feature's `fromEnv` option instead \
                 (§8.6)",
                path
            ));
        }
        _ => {}
    }
}

fn has_scheme(val: &str) -> bool {
    let at = match val.find("://") {
        Some(at) if 0 < at => at,
        _ => return false,
    };
    let scheme = &val[..at];
    let mut chars = scheme.chars();
    match chars.next() {
        Some(head) if head.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|head| head.is_ascii_alphanumeric() || '+' == head || '.' == head || '-' == head)
}

/// The SHAPE kindof, which must agree with struct's own spellings. NOT
/// the same function as the feature checker's (`feature::featurekind`) -
fn shapekind(val: &Json) -> &'static str {
    match val {
        Json::Null => "null",
        Json::List(_) => "list",
        Json::Map(_) => "object",
        Json::Bool(_) => "boolean",
        Json::Str(_) => "string",
        Json::Num(num) => {
            if num.is_finite() && *num == num.trunc() {
                "integer"
            } else {
                "decimal"
            }
        }
        Json::Opaque(_) => "opaque",
    }
}

// ---------------------------------------------------------------------
// The value seam: station's Json <-> struct's Value
// ---------------------------------------------------------------------

// Station's value model IS sekreto's Json (one dependency, one value
// Json's maps are BTreeMap, so a map's key order becomes BYTEWISE SORTED
// on the way across. That reaches exactly one observable place - the
// stringified spec inside a `$ONE` failure message - and every map the
// authored in sorted order already, so the messages are byte-identical.

pub fn json_to_value(val: &Json) -> Value {
    match val {
        Json::Null => Value::Null,
        Json::Bool(flag) => Value::Bool(*flag),
        Json::Num(num) => Value::Num(*num),
        Json::Str(text) => Value::Str(text.clone()),
        Json::List(items) => Value::list(items.iter().map(json_to_value).collect()),
        Json::Map(entries) => Value::map_of(
            entries
                .iter()
                .map(|(key, entry)| (key.clone(), json_to_value(entry))),
        ),
        // Never reached - see jsonx::jtextof's note on Opaque. struct has
        // no counterpart for a host object, and Null is the one spelling
        Json::Opaque(_) => Value::Null,
    }
}

/// non-data variants land as null: nothing station hands struct can
/// produce them, and an error value that carried one is still readable.
pub fn value_to_json(val: &Value) -> Json {
    match val {
        Value::Bool(flag) => Json::Bool(*flag),
        Value::Num(num) => Json::Num(*num),
        Value::Str(text) => Json::Str(text.clone()),
        Value::List(items) => Json::List(items.borrow().iter().map(value_to_json).collect()),
        Value::Map(entries) => {
            let mut out: BTreeMap<String, Json> = BTreeMap::new();
            for (key, entry) in entries.borrow().iter() {
                out.insert(key.clone(), value_to_json(entry));
            }
            Json::Map(out)
        }
        _ => Json::Null,
    }
}
