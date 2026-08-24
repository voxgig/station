//! The config grammar, as data (design §4).
//!
//! TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
//!
//! struct drops the unexpected-key check for a map whose spec node ends
//! up EMPTY - "an empty spec object means the object can be open". An
//! optional key is `['$ONE','$NIL', spec]`, and when the data does not
//! carry that key the validator REMOVES it from the spec node. So a
//! block whose keys are all optional degenerates into an open map
//! exactly when the data has none of them, and `{"solar": {"bass": 1}}`
//! validates clean - the one property the whole exercise is for,
//! silently absent in the one case that matters.
//!
//! So: `normalize_config` materializes every documented default, and
//! `validate_config` then runs a shape WITH NO OPTIONAL CONTAINERS AT
//! ALL. After normalization every container is present, so the shape can
//! require them, so unexpected-key detection is live at every level and
//! every error names its path.
//!
//! A port of typescript/src/shape.ts, which is canonical.

use std::collections::BTreeMap;

use voxgig_sekreto::{validname, Json};
use voxgig_struct::{clone as structclone, validate, InjectDef, Value};

use crate::descriptor::{canonical_serialize, envtoken};
use crate::error::StationError;
use crate::jsonx::{jget, jmap};

// ---------------------------------------------------------------------
// The defaults table - ONE table, two callers
// ---------------------------------------------------------------------

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

/// The block-level defaults. `feature` is a container and safe early.
///
/// `active` IS NOT, and that is the whole timing rule: a default
/// synthesized into an OVERLAY block overwrites the base's real value
/// and silently reactivates an integration the base deliberately barred
/// (§3.3). So the two consumers read this same table at different
/// moments - `validate_config` BEFORE, applied to every block, because a
/// block with no present keys is an open map; the profile resolver
/// AFTER, applied to the merged instance, because an absent key must
/// stay absent through the merge.
///
/// `profile::resolve_profile` is the second caller, and it reads this
/// table rather than a copy of it.
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

/// Materialize every documented default, DEFENSIVELY: a node that is not
/// the kind it expects is left alone for validate to reject with a
/// message that names the path. Pure data-in/data-out, which is what
/// makes it portable to sixteen languages and expressible in the corpus,
/// and it NEVER MUTATES ITS INPUT - Rust's ownership makes that a
/// guarantee rather than a discipline, since the input arrives by
/// reference and every map is rebuilt.
///
/// THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE.
pub fn normalize_config(raw: &Json) -> Json {
    let rawmap = match raw {
        Json::Map(entries) => entries,
        // Not a map: validate will reject it with a proper message.
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

/// Per feature entry, at every level: `active` -> true.
///
/// A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
/// own default is `active: false` for all but `log`, and
/// `{"retry": {"retries": 3}}` plainly means "retry, with three
/// attempts". It also keeps the feature map closed, for the same reason
/// every other block needs one present key.
///
/// Defensive like the rest: a non-map is returned untouched for validate
/// to reject by path.
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

/// `spec/config-shape.json`, §4.3 verbatim - the artifact every port
/// reads. This crate is PUBLISHED AND COMPILED: it cannot see `spec/` at
/// run time, and `validate_config` runs at open() rather than only under
/// test, so the shape is EMBEDDED as a mirror. `make sync-shape`
/// rewrites the mirror; tests/unit.rs deep-compares the two and fails on
/// drift.
const CONFIG_SHAPE_JSON: &str = include_str!("config-shape.json");

/// A FRESH DEEP COPY of the shape on every call.
///
/// struct's validate CONSUMES the spec it walks - it deletes satisfied
/// `$ONE` branches as it goes - so handing it one parsed value twice
/// would validate the second config against a spec the first had already
/// eaten. `struct::clone` is used rather than a re-parse so the cost is a
/// tree copy, not a parse.
pub fn config_shape() -> Value {
    thread_local! {
        static PARSED: Value = parse_shape();
    }
    PARSED.with(structclone)
}

fn parse_shape() -> Value {
    let parsed = voxgig_sekreto::json::parse(CONFIG_SHAPE_JSON)
        .expect("station: the embedded config shape is not valid JSON");
    json_to_value(&parsed)
}

/// The shape as station's own value model, for the port-local guard
/// tests (the drift check, and §0's optional shape assertions).
pub fn config_shape_json() -> Json {
    voxgig_sekreto::json::parse(CONFIG_SHAPE_JSON)
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

/// The suffix rule catches `access_key`, `X-Api-Token` and friends in
/// one rule rather than a growing list of spellings.
const CREDENTIAL_SUFFIX: [&str; 4] = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"];

/// §5.2's backstop, and it is stated as one rather than as a grammar.
/// `validname()` is a NAME grammar, not a credential filter: it rejects
/// uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
/// credential formats - but a lowercase hex token passes it cleanly. A
/// character class cannot tell a name from a secret.
///
/// Derived names break on every separator (`voxgig_solardemo.apikey`
/// runs 6/9/6) and a hand-written name for a human to read does too; a
/// 24-character unbroken run is not a name anybody writes. Note this is
/// a RUN bound, not a length bound: `acme_internal_billing_service.apikey`
/// is 36 characters and passes, which is the false positive a naive
/// length bound would produce.
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

/// Normalize, then validate (§4.2). Raises `station_config_invalid` with
/// EVERY struct error at once - an eighteen-instance config that touches
/// three of them must not die because the eighteenth has a typo'd
/// package name - then the §5.2 scans.
///
/// The §4.4 workarounds are merged into the SAME error as struct's own,
/// which is this tranche's one structural deviation from the canonical
/// two-throw order: a struct new enough to reject a first-element gap
/// itself reports a DIFFERENT spelling ("to be one of ..."), and the
/// corpus pins the explicit one - so the pinned message is produced here
/// either way, and behavior is identical whatever struct version
/// resolves.
///
/// Takes the NORMALIZED form. Handing it a raw config is the mistake
/// §4.2 exists to prevent, so every caller goes through
/// `normalize_config` first.
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

/// `plugin` is REMOVED, not aliased (§3.4) - a deprecated alias would be
/// a second grammar for one concept in sixteen ports. The shape already
/// rejects it as an unexpected key; this says WHAT TO RENAME, because
/// "unexpected key: plugin" alone does not, and the migration for a
/// single-instance project is exactly this one rename.
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

/// What the §5.2/§4.4 scans collect. Three lists, three error codes - and
/// they are COLLECTED rather than raised, because `validate_config` owns
/// the order.
#[derive(Default)]
struct Scanned {
    secrets: Vec<String>,
    reserved: Vec<String>,
    invalid: Vec<String>,
}

/// The §5.2 scans, over the parts of the grammar that hold arbitrary
/// data. Everything else is closed by construction and needs no scan -
/// `profiles.<p>.secrets.providers` INCLUDED, which is why a provider
/// block may legitimately carry its own `auth` sub-map and why
/// `config#twenty-sdk-fleet` passes.
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

                // The block's own `secret` holds a NAME. resolve_profile
                // checks it again per instance (station_secret_name);
                // this catches it at open(), for the whole file at once.
                if let Some(secret) = jget(block, "secret") {
                    secretvalue(secret, &format!("{}.secret", bpath), &mut out.secrets);
                }

                // `options` is passthrough to a generated constructor, so
                // it is the one place a value can hide.
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
                // reach, raising the same code the shape would - and
                // pinned in the corpus so each workaround is removed
                // deliberately when struct is fixed rather than
                // forgotten.
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

/// The policy block's §4.4 workarounds, in one place because they are one
/// class of gap: struct cannot check what its own defects hide.
///
/// - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists, so
///   element 0 escapes the shape (see `firstelement` below).
/// - `budget` is a map whose keys are ALL optional scalars, and struct
///   removes an unsatisfied optional key from the spec node - so
///   `budget: {rp: 1}` degenerates the spec into an open map and the typo
///   passes. `allow` does not have this problem (its `$CHILD` keys stay
///   in the spec whether or not the data carries them, keeping the map
///   closed), and neither does `policy` itself (`hosts` anchors it);
///   `budget` alone needs the explicit unexpected-key check, phrased as
///   struct would phrase it.
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
        // BTreeMap keys already iterate in sorted order, which is the
        // order the message wants.
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
/// upstream struct defect, filed as voxgig/struct#113.
///
/// It reaches THREE string lists in this shape: `policy.hosts`, and the
/// per-feature `order.before` / `order.after`. Applied where the shape
/// cannot reach, raising the same code the shape would, and pinned in the
/// corpus so the workaround is removed deliberately when struct is fixed
/// rather than forgotten.
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

                // §8.6: station owns feature composition, so an
                // `options.feature` in a declarative config is a second,
                // unreconciled ordering input - two representations of
                // one setting resolved differently by sixteen ports is
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
/// the very mechanism that keeps values out of the file. THREE checks,
/// first failure wins, and they live in the same handful of lines
/// precisely so a port cannot implement only the first and inherit the
/// gap the others exist to close.
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
/// failure is not an error - it returns silently.
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

/// `^[a-zA-Z][a-zA-Z0-9+.-]*://`, without a regex engine.
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
/// they disagree on numbers and maps deliberately, and unifying them
/// would make one of the two message sets wrong.
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
    }
}

// ---------------------------------------------------------------------
// The value seam: station's Json <-> struct's Value
// ---------------------------------------------------------------------

// Station's value model IS sekreto's Json (one dependency, one value
// type - design §10), and struct carries its own `Value` because it needs
// reference-stable nodes and an insertion-ordered map. The two meet HERE
// and nowhere else: validate_config converts on the way in, and reads
// struct's collected errors back on the way out.
//
// Json's maps are BTreeMap, so a map's key order becomes BYTEWISE SORTED
// on the way across. That reaches exactly one observable place - the
// stringified spec inside a `$ONE` failure message - and every map the
// shape puts inside a `$ONE` (`policy`, `allow`, `budget`, `agent`) is
// authored in sorted order already, so the messages are byte-identical.

/// station Json -> struct Value.
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
    }
}

/// struct Value -> station Json. `Noval` (struct's `undefined`) and the
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
