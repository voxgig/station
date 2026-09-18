
use crate::descriptor::canonical_serialize;
use crate::error::StationError;
use voxgig_sekreto::voxgig_plugin::value::Value as Json;

/// The fixed alias every generated package exports, and the first
/// constructor name a loader-language port tries.
pub const DEFAULT_EXPORT: &str = "SDK";

pub fn check_package(api: &str, pkg: &str) -> Result<String, StationError> {
    let mut bad = pkg.is_empty()
        || pkg.starts_with('.')
        || pkg.starts_with('/')
        || pkg.starts_with('~')
        || pkg.contains("://")
        || pkg.contains('\\');

    if !bad {
        for segment in pkg.split('/') {
            if "." == segment || ".." == segment {
                bad = true;
                break;
            }
        }
    }

    if bad {
        return Err(StationError::new(
            "station_sdk_load",
            format!(
                "api \"{}\": `package` must be a module name resolved from the \
                 application root, not a path or URL: {}",
                api,
                canonical_serialize(&Json::Str(pkg.to_string()))
            ),
        ));
    }
    Ok(pkg.to_string())
}

/// `stripe-eu` -> `StripeEu`: split on runs of non-alphanumerics,
/// upper-case each first character, join. The derived constructor name a
/// once for the whole fleet.
pub fn camelify(slug: &str) -> String {
    let mut out = String::new();
    for part in slug.split(|head: char| !head.is_ascii_alphanumeric()) {
        let mut chars = part.chars();
        if let Some(head) = chars.next() {
            out.push(head.to_ascii_uppercase());
            out.push_str(chars.as_str());
        }
    }
    out
}
