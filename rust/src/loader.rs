//! §6.3's LOADER, and why this module has no loader in it.
//!
//! Three paths fill the factory table (§6.2): module self-registration,
//! `Station::provide`, and the loader - `api.<slug>.package`, which
//! station imports BY NAME at run time so the config closes the loop on
//! its own.
//!
//! RUST HAS THE THIRD PATH NOWHERE AND THE FIRST ONE NOWHERE EITHER.
//! There is no import-by-name at run time: a Rust dependency is linked,
//! and loading one at run time means `dlopen` over an unstable ABI, which
//! is a different artifact with its own toolchain constraints rather than
//! the ordinary dependency graph a reviewer reads in Cargo.toml. And
//! there is no module-init hook - no `func init()`, no import side
//! effect, nothing that runs when a crate is merely linked - so a
//! generated crate cannot register itself either. `#[ctor]`-style
//! constructors exist only as a third-party crate, and this library takes
//! no dependency beyond sekreto and struct.
//!
//! SO THIS PORT HAS EXACTLY ONE OF THE THREE PATHS: `Station::provide`
//! (or the free `factory::provide`), called by the application - one line
//! per api, and every other line of configuration stays in JSON. It says
//! so in README.md, in the `station_no_factory` message, and in one
//! warning event per api at open() for a config that carries `package`
//! anyway.
//!
//! `package` and `export` STAY IN THE GRAMMAR: they are shape keys, the
//! corpus validates configs that carry them (`config#twenty-sdk-fleet`
//! has four `package` values), and one station.json serves a polyglot
//! fleet. Ignoring a key is this port's business; removing it from the
//! grammar would be everyone's.
//!
//! What survives from typescript/src/loader.ts is `check_package`, which
//! is PURE: the rule for what may appear in that key at all. It is
//! exported so a Rust-side tool can hold a shared config to the same rule
//! the ports that DO load will apply, and nothing in this port calls it -
//! which is why `station_sdk_load`, though it stays in the §14 catalog
//! that the `errors` corpus section pins, is never raised here.

use crate::descriptor::canonical_serialize;
use crate::error::StationError;
use voxgig_sekreto::Json;

/// The fixed alias every generated package exports, and the first
/// constructor name a loader-language port tries.
pub const DEFAULT_EXPORT: &str = "SDK";

/// Only MODULE NAMES, resolved by the host language's ordinary resolution
/// from the application root: never a filesystem path, never a URL, never
/// anything relative.
///
/// THE SEGMENT CHECK IS NOT OPTIONAL AND IS NOT IMPLIED BY THE PREFIX
/// CHECKS. `pkg/../../escape` starts with neither `.` nor `/`, so a
/// first-character check passes it, and a host that resolves it walks out
/// of the named dependency and imports application-local code from
/// outside it. The whole point of this function is that a configured
/// package stays inside the dependency graph a reviewer can see.
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
/// loader-language port tries second, kept here so the rule is stated
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
