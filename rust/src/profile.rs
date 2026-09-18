
use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};

use voxgig_sekreto::validname;
use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::error::StationError;
use crate::jsonx::{jget, jmap, jstr};

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
    match voxgig_sekreto::voxgig_plugin::value::parse(&text) {
        Ok(parsed) => Ok(Some(parsed)),
        Err(why) => Err(StationError::new(
            "station_config_invalid",
            format!(
                "station.json at {} is not valid JSON: {}",
                file.display(),
                why
            ),
        )),
    }
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
