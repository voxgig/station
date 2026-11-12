
use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};

use voxgig_sekreto::validname;
use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::error::StationError;
use crate::jsonx::{jget, jmap, jstr, jtext};

pub fn find_config_file(from: Option<&Path>) -> Option<PathBuf> {
    let start = match from {
        Some(dir) => dir.to_path_buf(),
        None => env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    };
    let mut dir = start;
    loop {
        let candidate = dir.join("station.json");
        if candidate.exists() {
            return Some(candidate);
        }
        let at_repo_root = dir.join(".git").exists();
        let parent = dir.parent().map(|p| p.to_path_buf());
        match parent {
            Some(parent) if !at_repo_root && parent != dir => dir = parent,
            _ => break,
        }
    }
    let home = env::var("HOME").unwrap_or_default();
    if !home.is_empty() {
        let fallback = Path::new(&home).join(".voxgig").join("station.json");
        if fallback.exists() {
            return Some(fallback);
        }
    }
    None
}

pub fn load_config(from: Option<&Path>) -> Result<Option<Json>, StationError> {
    let file = match find_config_file(from) {
        Some(file) => file,
        None => return Ok(None),
    };
    let text = std::fs::read_to_string(&file).map_err(|err| {
        StationError::new(
            "station_config_invalid",
            format!("station.json at {} cannot be read: {}", file.display(), err),
        )
    })?;
    parse_config(&text, Some(&file.display().to_string())).map(Some)
}

/// Decodes station.json text; `file` names it in a refusal. A file that is
/// not JSON is a config error. Decoders disagree about an unpaired surrogate
/// escape, which I-JSON forbids, so the text is scanned before it is decoded.
pub fn parse_config(text: &str, file: Option<&str>) -> Result<Json, StationError> {
    let place = match file {
        Some(file) => format!("station.json at {}", file),
        None => "station.json".to_string(),
    };
    if let Some(literal) = unpaired_surrogate(text) {
        return Err(StationError::new(
            "station_config_invalid",
            format!("{} has an unpaired surrogate escape in {}", place, literal),
        ));
    }
    voxgig_sekreto::voxgig_plugin::value::parse(text).map_err(|why| {
        StationError::new(
            "station_config_invalid",
            format!("{} is not valid JSON: {}", place, why),
        )
    })
}

// The first closed string literal, quotes included, holding a \u escape
// for a surrogate that is not half of an escaped pair. Read by byte: no
// byte of a multibyte character is a quote or a backslash.
fn unpaired_surrogate(text: &str) -> Option<&str> {
    let bytes = text.as_bytes();
    let mut start: Option<usize> = None;
    let mut unpaired = false;
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        match start {
            None => {
                if b'"' == c {
                    start = Some(i);
                    unpaired = false;
                }
            }
            Some(open) => {
                if b'"' == c {
                    if unpaired {
                        return Some(&text[open..=i]);
                    }
                    start = None;
                } else if b'\\' == c {
                    let unit = escaped_unit(bytes, i);
                    if is_high_surrogate(unit) && is_low_surrogate(escaped_unit(bytes, i + 6)) {
                        i += 11;
                    } else if is_high_surrogate(unit) || is_low_surrogate(unit) {
                        unpaired = true;
                        i += 5;
                    } else {
                        i += 1;
                    }
                }
            }
        }
        i += 1;
    }
    None
}

fn escaped_unit(bytes: &[u8], at: usize) -> i32 {
    if at + 6 > bytes.len() || b'\\' != bytes[at] || b'u' != bytes[at + 1] {
        return -1;
    }
    let mut unit = 0;
    for &byte in &bytes[at + 2..at + 6] {
        let digit = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            b'A'..=b'F' => byte - b'A' + 10,
            _ => return -1,
        };
        unit = unit * 16 + i32::from(digit);
    }
    unit
}

fn is_high_surrogate(unit: i32) -> bool {
    (0xD800..=0xDBFF).contains(&unit)
}

fn is_low_surrogate(unit: i32) -> bool {
    (0xDC00..=0xDFFF).contains(&unit)
}

pub fn config_scope(from: Option<&Path>) -> String {
    let file = match find_config_file(from) {
        Some(file) => file,
        None => return "none".to_string(),
    };
    let home = env::var("HOME").unwrap_or_default();
    if !home.is_empty() {
        let user = Path::new(&home).join(".voxgig").join("station.json");
        if file == user {
            return "user".to_string();
        }
    }
    "repo".to_string()
}

/// Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
/// else 'default' (design §3.5 - env vars rank above station.json but
/// below open() opts).
pub fn select_profile(opt_profile: Option<&str>) -> String {
    if let Some(profile) = opt_profile {
        if !profile.is_empty() {
            return profile.to_string();
        }
    }
    if let Ok(profile) = env::var("VOXGIG_STATION_PROFILE") {
        if !profile.is_empty() {
            return profile;
        }
    }
    "default".to_string()
}

/// The resolved view one Station runs with.
#[derive(Clone, Debug)]
pub struct ResolvedProfile {
    pub name: String,
    /// sekreto ProviderSpec forms, verbatim from station.json (§5.2).
    pub providers: Vec<Json>,
    pub api: BTreeMap<String, Json>,
    pub sdk: BTreeMap<String, Json>,
}

pub use crate::shape::{block_defaults, MERGE_SENSITIVE};

pub fn refapi(reference: &str) -> String {
    match reference.find('$') {
        Some(at) => reference[..at].to_string(),
        None => reference.to_string(),
    }
}

fn shallow(sources: &[Option<&Json>]) -> Json {
    let mut out: BTreeMap<String, Json> = BTreeMap::new();
    for src in sources.iter().flatten() {
        if let Json::Map(entries) = src {
            for (k, v) in entries.iter() {
                out.insert(k.clone(), v.clone());
            }
        }
    }
    Json::Map(out)
}

fn merged_keys(maps: &[Option<&BTreeMap<String, Json>>]) -> Vec<String> {
    let mut keys: BTreeMap<String, ()> = BTreeMap::new();
    for m in maps.iter().flatten() {
        for k in m.keys() {
            keys.insert(k.clone(), ());
        }
    }
    keys.into_keys().collect()
}

pub fn resolve_profile(
    config: Option<&Json>,
    profile_name: &str,
) -> Result<ResolvedProfile, StationError> {
    let empty = Json::Map(BTreeMap::new());
    let profiles = config.and_then(|c| jget(c, "profiles")).unwrap_or(&empty);
    let base = jget(profiles, "default").unwrap_or(&empty);
    let overlay = if "default" == profile_name {
        &empty
    } else {
        jget(profiles, profile_name).unwrap_or(&empty)
    };

    let providers: Vec<Json> = jget(overlay, "secrets")
        .and_then(|s| jlist_of(s, "providers"))
        .or_else(|| jget(base, "secrets").and_then(|s| jlist_of(s, "providers")))
        .unwrap_or_else(|| vec![crate::jsonx::jobj(vec![("kind", Json::Str("env".to_string()))])]);

    let base_api = jmap(base, "api");
    let over_api = jmap(overlay, "api");
    let base_sdk = jmap(base, "sdk");
    let over_sdk = jmap(overlay, "sdk");

    let mut api: BTreeMap<String, Json> = BTreeMap::new();
    for slug in merged_keys(&[base_api, over_api]) {
        api.insert(
            slug.clone(),
            shallow(&[
                base_api.and_then(|m| m.get(&slug)),
                over_api.and_then(|m| m.get(&slug)),
            ]),
        );
    }

    let mut sdk: BTreeMap<String, Json> = BTreeMap::new();
    for reference in merged_keys(&[base_sdk, over_sdk]) {
        let a = refapi(&reference);
        let merged = shallow(&[
            base_api.and_then(|m| m.get(&a)),
            base_sdk.and_then(|m| m.get(&reference)),
            over_api.and_then(|m| m.get(&a)),
            over_sdk.and_then(|m| m.get(&reference)),
        ]);

        // Defaults are applied ONCE, to the fully merged instance. Had
        // the overlay block carried a synthesized `active` into the
        // merge, a one-key environment override would silently re-enable
        // an integration the base declared inactive.
        let merged = match merged {
            Json::Map(mut entries) => {
                for (k, v) in block_defaults() {
                    entries.entry(k.to_string()).or_insert(v);
                }
                Json::Map(entries)
            }
            other => other,
        };

        sdk.insert(reference, merged);
    }

    checksecrets(&sdk, profile_name)?;

    Ok(ResolvedProfile {
        name: profile_name.to_string(),
        providers,
        api,
        sdk,
    })
}

fn checksecrets(
    sdk: &BTreeMap<String, Json>,
    profile_name: &str,
) -> Result<(), StationError> {
    for (reference, val) in sdk.iter() {
        let name = jstr(val, "secret");
        let has_secret = matches!(jget(val, "secret"), Some(Json::Str(_)));
        if has_secret && !validname(&name) {
            return Err(StationError::new(
                "station_secret_name",
                format!(
                    "profile \"{}\" sdk \"{}\": secret name rejected by sekreto: \"{}\"",
                    profile_name, reference, name
                ),
            ));
        }
    }

    let mut seen: BTreeMap<String, (String, bool)> = BTreeMap::new();
    for (reference, val) in sdk.iter() {
        let written = jstr(val, "secret");
        let derived = written.is_empty();
        let name = if derived {
            crate::descriptor::secretname_default(reference)
        } else {
            written
        };

        if let Some((prior, prior_derived)) = seen.get(&name) {
            if derived || *prior_derived {
                return Err(StationError::new(
                    "station_secret_collision",
                    format!(
                        "profile \"{}\": instances \"{}\" and \"{}\" both resolve to \
                         secret name \"{}\", so they would share one credential; name it \
                         explicitly on each, or at the api level to share it \
                         deliberately (§5.1)",
                        profile_name, prior, reference, name
                    ),
                ));
            }
        } else {
            seen.insert(name, (reference.clone(), derived));
        }
    }
    Ok(())
}

fn jlist_of(val: &Json, key: &str) -> Option<Vec<Json>> {
    match jget(val, key) {
        Some(Json::List(items)) => Some(items.clone()),
        _ => None,
    }
}

/// The block that governs an instance: its own, else its api's.
pub fn block_of(profile: &ResolvedProfile, reference: &str) -> Json {
    profile
        .sdk
        .get(reference)
        .or_else(|| profile.api.get(&refapi(reference)))
        .cloned()
        .unwrap_or_else(|| Json::Map(BTreeMap::new()))
}

/// §3.5 for a named instance: the block's `options`, then its `base`
/// (steps 3-6), under the caller's options (step 9), per top-level key.
pub fn instance_options(block: &Json, opts: Option<&Json>) -> BTreeMap<String, Json> {
    let mut out: BTreeMap<String, Json> = match jget(block, "options") {
        Some(Json::Map(entries)) => entries.clone(),
        _ => BTreeMap::new(),
    };
    let base = jstr(block, "base");
    if !base.is_empty() {
        out.insert("base".to_string(), jtext(base));
    }
    if let Some(Json::Map(extra)) = opts {
        for (key, val) in extra.iter() {
            out.insert(key.clone(), val.clone());
        }
    }
    out
}
