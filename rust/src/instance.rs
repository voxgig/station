//! The instance ref grammar (design §6.1), pinned by the `instanceref`
//! corpus section.
//!
//! A port of the instanceRef/checkref half of typescript/src/Station.ts,
//! which is canonical. It lives in its own module here because Rust has
//! no class body to hang free functions off, and this is the one piece of
//! Station.ts that is pure over (api, opts).

use voxgig_sekreto::Json;

use crate::error::StationError;
use crate::jsonx::jstr;
use crate::profile::refapi;

/// The ref grammar is the JOINT identity model's (station-and-plugin.md
/// §2, plugin design §4): a name is a package-ish specifier
/// (`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`), a tag is not
/// (`^[a-zA-Z0-9.~_-]+$` or empty - it MAY start with a digit, because
/// auto-tagging assigns integer tags, and admits neither `@` nor `/`);
/// both cap at 1024; the split is on the FIRST `$`, so `a$b$c` is a good
/// name with a bad tag.
const REF_MAX: usize = 1024;

/// Whether a ref's name half is well formed.
///
/// The two character classes are spelled out rather than compiled,
/// because this library takes no regex dependency and the grammar is two
/// classes wide.
pub fn check_instance_name(name: &str) -> bool {
    if name.is_empty() || REF_MAX < name.chars().count() {
        return false;
    }
    let mut chars = name.chars();
    match chars.next() {
        Some(head) if head.is_ascii_alphabetic() || '@' == head => {}
        _ => return false,
    }
    chars.all(namechar)
}

fn namechar(head: char) -> bool {
    head.is_ascii_alphanumeric()
        || '.' == head
        || '~' == head
        || '_' == head
        || '-' == head
        || '/' == head
}

/// Whether a ref's tag half is well formed. THE EMPTY TAG IS AN ORDINARY
/// TAG: the single-instance case writes no tag and never learns tags
/// exist.
pub fn check_instance_tag(tag: &str) -> bool {
    if tag.is_empty() {
        return true;
    }
    if REF_MAX < tag.chars().count() {
        return false;
    }
    tag.chars()
        .all(|head| head.is_ascii_alphanumeric() || '.' == head || '~' == head || '_' == head || '-' == head)
}

/// name, tag, and whether a `$` was present at all.
fn cutref(reference: &str) -> (&str, &str, bool) {
    match reference.find('$') {
        Some(at) => (&reference[..at], &reference[at + 1..], true),
        None => (reference, "", false),
    }
}

/// Validate a ref against the joint grammar and return its CANONICAL
/// spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
/// `stripe` are ONE registry key rather than two.
pub fn check_ref(reference: &str) -> Result<String, StationError> {
    let (name, tag, tagged) = cutref(reference);
    if !check_instance_name(name) {
        return Err(StationError::new(
            "station_instance_api",
            format!(
                "invalid instance name \"{}\" in ref \"{}\": a name starts with \
                 a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (§6.1)",
                name, reference
            ),
        ));
    }
    if !check_instance_tag(tag) {
        return Err(StationError::new(
            "station_instance_api",
            format!(
                "invalid instance tag \"{}\" in ref \"{}\": a tag uses \
                 `[a-zA-Z0-9.~_-]`, max 1024 (§6.1)",
                tag, reference
            ),
        ));
    }
    if !tagged || tag.is_empty() {
        return Ok(name.to_string());
    }
    Ok(reference.to_string())
}

fn checkapi(api: &str, reference: &str) -> Result<(), StationError> {
    if refapi(reference) != api {
        return Err(StationError::new(
            "station_instance_api",
            format!(
                "instance \"{}\" names api \"{}\", but the SDK passed is api \
                 \"{}\"; `as` is a tag, not a free name (§6.1)",
                reference,
                refapi(reference),
                api
            ),
        ));
    }
    Ok(())
}

/// The instance name one construction registers under. §6.1: `as` IS A
/// TAG, NOT A FREE NAME.
///
/// The api comes from the SDK being built, so the resulting ref is
/// `<api>$<tag>` and multi-instance works imperatively too. A full ref is
/// also accepted and is VALIDATED: its name must equal the api slug, or
/// it is `station_instance_api`. An `as` that took an arbitrary name
/// would reintroduce exactly the second-identity problem the ref re-key
/// removed - under the ref invariant `as: "solar-eu"` would denote the
/// untagged `solar-eu` DEFINITION rather than an instance of the SDK just
/// handed in, and registry grouping, api defaults and every ref consumer
/// would disagree about what it is.
///
/// A bare build with no name falls back to the api slug, which is today's
/// behaviour and why the single-instance case is unchanged to the byte.
pub fn instance_ref(api: &str, fopts: &Json) -> Result<String, StationError> {
    let explicit = jstr(fopts, "instance");
    if !explicit.is_empty() {
        checkapi(api, &explicit)?;
        return check_ref(&explicit);
    }

    let as_tag = jstr(fopts, "as");

    // The bare fallback is the SLUG - a name, never a ref: a `$` in it is
    // an invalid name, not an implicit tag.
    if as_tag.is_empty() {
        if !check_instance_name(api) {
            return Err(StationError::new(
                "station_instance_api",
                format!(
                    "invalid instance name \"{}\": a name starts with a letter \
                     or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (§6.1)",
                    api
                ),
            ));
        }
        return Ok(api.to_string());
    }

    // A `$`-LESS STRING IS ALWAYS A TAG, and a `$`-bearing one is a full
    // ref validated against the api.
    //
    // §6.1 gives both branches and does not say how to disambiguate a
    // `$`-less string, which is a real ambiguity because a bare name is
    // itself a valid (untagged) ref: `as: "stripe"` on api `stripe` could
    // read as the untagged ref `stripe` or as tag `stripe`. It is read as
    // a TAG, giving `stripe$stripe`, because §6.1 says twice and
    // emphatically that `as` is a tag rather than a free name, and a rule
    // with no exceptions is the one that ports the same way twenty times.
    // Someone who wants the untagged instance passes no `as` at all,
    // which is the documented spelling for it.
    let (_, _, tagged) = cutref(&as_tag);
    if !tagged {
        return check_ref(&format!("{}${}", api, as_tag));
    }
    checkapi(api, &as_tag)?;
    check_ref(&as_tag)
}
