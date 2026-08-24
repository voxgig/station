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
///
/// A JSON parse failure is `station_config_invalid` NAMING THE FILE, not
/// a raw parser error escaping open(): the one thing a person needs when
/// a config will not load is which file it was, and the canonical port
/// wraps it at exactly this moment for the same reason. An unreadable
/// file (present, but the process cannot read it) is the same class of
/// misconfiguration and carries the io error.
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
    match voxgig_sekreto::json::parse(&text) {
        Some(parsed) => Ok(Some(parsed)),
        None => Err(StationError::new(
            "station_config_invalid",
            format!(
                "station.json at {} is not valid JSON: the parser found no value",
                file.display()
            ),
        )),
    }
}

/// Which side of §6.3's review boundary the discovered config came from:
/// `none` when the lookup found no file, `user` when it found
/// `~/.voxgig/station.json`, else `repo`.
///
/// `package` and `export` are honoured only from REPO-SCOPED config,
/// because a user-level file sits outside the repo's review boundary and
/// a `package` key arriving from it names CODE TO LOAD. Everything else
/// in a user-level config still applies - this narrows one key rather
/// than distrusting the file.
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
    /// The api-level defaults in effect for this profile, keyed by api
    /// slug. A REPORT, not an input to the instance merge - collapsing
    /// each namespace first and composing at the end is the exact
    /// algorithm §3.3 forbids.
    pub api: BTreeMap<String, Json>,
    /// Resolved instances, keyed by REF (`api$tag`, or a bare `api` for
    /// the untagged one). An api block declares no instance of its own
    /// (§3.1), so it never creates an entry here.
    pub sdk: BTreeMap<String, Json>,
}

// The block defaults and the one merge-sensitive key among them live in
// shape.rs: ONE TABLE, TWO CALLERS AT DIFFERENT MOMENTS (§4.2).
// validate_config applies it BEFORE, to every block, because a block with
// no present keys is an open map; the resolver below applies it AFTER, to
// the merged instance, because an absent key must stay absent through the
// merge.
pub use crate::shape::{block_defaults, MERGE_SENSITIVE};

/// The api half of a ref: the substring before the first `$`. An
/// untagged ref IS an api slug (§3.4).
///
/// LEXICAL, and that is the point: under the old free-form identity
/// which api an instance used was itself a merged value, so a port that
/// got the phasing wrong silently picked another api's defaults.
pub fn refapi(reference: &str) -> String {
    match reference.find('$') {
        Some(at) => reference[..at].to_string(),
        None => reference.to_string(),
    }
}

/// Shallow merge, per key, left to right - each source over the one
/// before it. An overlay's `policy` REPLACES the base's entirely rather
/// than merging `hosts` into it; an allowlist that widens because two
/// precedence levels merged is the failure this rule prevents.
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

/// Merge the base profile ('default') with the selected overlay.
///
/// §3.3's total order for the two block levels, lowest precedence first:
///
/// ```text
/// base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
/// ```
///
/// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
/// LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
/// namespace, then put instance over api" - that lets every instance
/// value beat every api value, so a production `api.stripe.policy` would
/// fail to override a default profile's `sdk.stripe$test.policy`,
/// silently keeping the wider allowlist in production.
///
/// `secrets.providers` replaces wholesale, never merges (§3.5, §5.2).
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

/// A configured secret name sekreto would reject is caught at profile
/// load, not first request (§14 station_secret_name) - and then the
/// DERIVED names are checked for uniqueness, because envtoken is LOSSY.
///
/// It collapses any run of non-alphanumerics to `_`, so `stripe$test` and
/// an untagged instance of a `stripe-test` api both derive
/// `stripe_test.apikey` and would silently share one credential.
///
/// Two instances that EXPLICITLY name one secret are not a collision -
/// that is the shared-key case the api-level `secret` exists for.
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
