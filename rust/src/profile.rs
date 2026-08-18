//! station.json lookup and profile resolution (design §3.5).
//!
//! A port of typescript/src/profile.ts, which is canonical: lookup walks
//! cwd upward to the repo root (where .git lives), then
//! ~/.voxgig/station.json; profile selection is open() opts, else
//! VOXGIG_STATION_PROFILE, else 'default'; the merge is deep per plugin
//! EXCEPT secrets.providers, which replaces wholesale (§3.5, §5.2 - chain
//! order decides which store wins, so a positional merge would be
//! actively dangerous). The `profile` corpus section pins all of this.

use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};

use voxgig_sekreto::{validname, Json};

use crate::error::StationError;
use crate::jsonx::{jget, jmap, jstr};

/// station.json lookup: `from` (or cwd) upward to the repo root, then
/// ~/.voxgig/station.json. A repo root is where .git lives; with no repo
/// the walk stops at the filesystem root.
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

/// Load the discovered station.json, or None when there is none.
/// An unreadable or unparseable file is construction-time
/// misconfiguration and panics with the offending path (the canonical
/// port throws from JSON.parse at the same moment).
pub fn load_config(from: Option<&Path>) -> Option<Json> {
    let file = find_config_file(from)?;
    let text = std::fs::read_to_string(&file)
        .unwrap_or_else(|err| panic!("station: cannot read {}: {}", file.display(), err));
    match voxgig_sekreto::json::parse(&text) {
        Some(parsed) => Some(parsed),
        None => panic!("station: cannot parse {}", file.display()),
    }
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
    /// Per-plugin config, deep-merged base-then-overlay.
    pub plugin: BTreeMap<String, Json>,
}

/// Merge the base profile ('default') with the selected overlay:
/// deep-merge per plugin, EXCEPT secrets.providers which replaces
/// wholesale. A configured secret name sekreto would reject is caught at
/// profile load, not first request (design §14 station_secret_name).
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

    let mut plugin: BTreeMap<String, Json> = BTreeMap::new();
    for src in [base, overlay] {
        if let Some(entries) = jmap(src, "plugin") {
            for (slug, val) in entries.iter() {
                let merged = match (plugin.get(slug), val) {
                    (Some(Json::Map(have)), Json::Map(add)) => {
                        let mut out = have.clone();
                        for (key, entry) in add.iter() {
                            out.insert(key.clone(), entry.clone());
                        }
                        Json::Map(out)
                    }
                    _ => val.clone(),
                };
                plugin.insert(slug.clone(), merged);
            }
        }
    }

    for (slug, val) in plugin.iter() {
        let name = jstr(val, "secret");
        let has_secret = matches!(jget(val, "secret"), Some(Json::Str(_)));
        if has_secret && !validname(&name) {
            return Err(StationError::new(
                "station_secret_name",
                format!(
                    "profile \"{}\" plugin \"{}\": secret name rejected by sekreto: \"{}\"",
                    profile_name, slug, name
                ),
            ));
        }
    }

    Ok(ResolvedProfile {
        name: profile_name.to_string(),
        providers,
        plugin,
    })
}

fn jlist_of(val: &Json, key: &str) -> Option<Vec<Json>> {
    match jget(val, key) {
        Some(Json::List(items)) => Some(items.clone()),
        _ => None,
    }
}
