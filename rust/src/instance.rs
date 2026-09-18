
use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::error::StationError;
use crate::jsonx::jstr;
use crate::profile::refapi;

const REF_MAX: usize = 1024;

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

/// `<api>$<tag>` and multi-instance works imperatively too. A full ref is
/// removed - under the ref invariant `as: "solar-eu"` would denote the
/// untagged `solar-eu` DEFINITION rather than an instance of the SDK just
/// handed in, and registry grouping, api defaults and every ref consumer
/// A bare build with no name falls back to the api slug, which is today's
pub fn instance_ref(api: &str, fopts: &Json) -> Result<String, StationError> {
    let explicit = jstr(fopts, "instance");
    if !explicit.is_empty() {
        checkapi(api, &explicit)?;
        return check_ref(&explicit);
    }

    let as_tag = jstr(fopts, "as");

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

    // `$`-less string, which is a real ambiguity because a bare name is
    let (_, _, tagged) = cutref(&as_tag);
    if !tagged {
        return check_ref(&format!("{}${}", api, as_tag));
    }
    checkapi(api, &as_tag)?;
    check_ref(&as_tag)
}
