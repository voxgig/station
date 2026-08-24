//! Feature management (design §8): the three-level merge, the
//! constraint-and-band resolver, and the descriptor-derived checker.
//!
//! The resolver is written to voxgig/plugin's §7 semantics so plugin can
//! extract it - this is one of the pieces the joint plan means by
//! "station builds natively to plugin's semantics".
//!
//! A port of typescript/src/feature.ts, which is canonical.
//!
//! DECLARATION ORDER, AND WHERE THIS PORT GETS IT. §8.4's LAST tie-break
//! is the order the config declared its features in. Station's value
//! model IS sekreto's `Json`, whose maps are `BTreeMap` - and omni's Json
//! is a `BTreeMap` too, so the authored order is already gone before a
//! corpus entry reaches a driver. `resolve_order` therefore takes the
//! declared order as an EXPLICIT list, exactly as the Go port does, and
//! falls back to bytewise key order when it is empty - which is every
//! caller in this port today. Deterministic, and identical to the
//! authored order whenever the config is authored in sorted order (as
//! every corpus entry is). README.md states the divergence.

use std::collections::{BTreeMap, BTreeSet};

use voxgig_sekreto::Json;

use crate::descriptor::canonical_serialize;
use crate::error::StationError;
use crate::jsonx::{jget, jmap};

// ---------------------------------------------------------------------
// §8.3 - the merge
// ---------------------------------------------------------------------

/// Reserved on a feature entry: not options, and never passed through to
/// the SDK's own option map.
pub const RESERVED_KEYS: [&str; 2] = ["active", "order"];

/// `test` substitutes the base transport, so it takes the innermost
/// band; `station` sits immediately outside it, pinned; everything else
/// is band 0, outside station.
///
/// THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
/// than as a special case: a project that writes no `order` anywhere sees
/// exactly today's nesting, and sdkgen's two `makeOptions` special cases
/// become two band values rather than two branches.
pub const BAND_DEFAULT: f64 = 0.0;
pub const BAND_STATION: f64 = 100.0;
pub const BAND_TEST: f64 = 200.0;

/// Higher is further IN.
pub fn default_band(name: &str) -> f64 {
    match name {
        "test" => BAND_TEST,
        "station" => BAND_STATION,
        _ => BAND_DEFAULT,
    }
}

/// The two-level merge - per feature name, then per option key, and NO
/// DEEPER.
///
/// `feature` is the ONE key where §3.3's shallow-per-key rule is wrong:
/// composition is the entire point, a fleet default plus a per-instance
/// tweak. A map-valued OPTION replaces wholesale, which is the depth
/// boundary `{"$MERGE": {"deep": 2}}` states and what a port defaulting
/// to a deep merge would silently get wrong.
///
/// NO DEFAULTS ARE SYNTHESIZED HERE - the caller passes RAW blocks. An
/// entry mentioned at one level with only a tuning key must NOT
/// synthesize `active` and switch on a feature a broader level turned
/// off. That is the §3.3 defect one level down.
pub fn merge_features(sources: &[Option<&Json>]) -> Json {
    let mut out: BTreeMap<String, Json> = BTreeMap::new();
    for src in sources.iter().flatten() {
        let entries = match src {
            Json::Map(entries) => entries,
            _ => continue,
        };
        for (name, entry) in entries.iter() {
            let fields = match entry {
                Json::Map(fields) => fields,
                other => {
                    // A non-map entry replaces wholesale.
                    out.insert(name.clone(), other.clone());
                    continue;
                }
            };
            let mut acc = match out.get(name) {
                Some(Json::Map(prior)) => prior.clone(),
                _ => BTreeMap::new(),
            };
            // Per option key, and NOT deeper.
            for (key, val) in fields.iter() {
                acc.insert(key.clone(), val.clone());
            }
            out.insert(name.clone(), Json::Map(acc));
        }
    }
    Json::Map(out)
}

/// The six sources for one instance, in §3.3's order extended by the
/// profile level:
///
/// ```text
/// 1 base.feature            4 overlay.feature
/// 2 base.api[<api>].feature 5 overlay.api[<api>].feature
/// 3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
/// ```
///
/// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
/// the narrower block wins - the same principle as §3.3, one level down.
/// Assembled here rather than at the call site so the order lives in
/// exactly one place.
pub fn feature_sources<'a>(
    base: Option<&'a Json>,
    overlay: Option<&'a Json>,
    api: &str,
    reference: &str,
) -> Vec<Option<&'a Json>> {
    vec![
        base.and_then(|b| jget(b, "feature")),
        base.and_then(|b| jget(b, "api"))
            .and_then(|a| jget(a, api))
            .and_then(|blk| jget(blk, "feature")),
        base.and_then(|b| jget(b, "sdk"))
            .and_then(|s| jget(s, reference))
            .and_then(|blk| jget(blk, "feature")),
        overlay.and_then(|o| jget(o, "feature")),
        overlay
            .and_then(|o| jget(o, "api"))
            .and_then(|a| jget(a, api))
            .and_then(|blk| jget(blk, "feature")),
        overlay
            .and_then(|o| jget(o, "sdk"))
            .and_then(|s| jget(s, reference))
            .and_then(|blk| jget(blk, "feature")),
    ]
}

// ---------------------------------------------------------------------
// §8.4 - activation and order
// ---------------------------------------------------------------------

/// One row of the resolved order, OUTERMOST FIRST.
#[derive(Clone, Debug)]
pub struct Ordered {
    pub name: String,
    pub band: f64,
    pub entry: Json,
}

/// A feature named in the config is one you are ASKING for, so an entry
/// with no `active` is active.
pub fn active(entry: &Json) -> bool {
    match entry {
        Json::Map(fields) => !matches!(fields.get("active"), Some(Json::Bool(false))),
        Json::Bool(false) => false,
        _ => true,
    }
}

/// The names of a merged map, in DECLARED order first and then any key
/// the order did not name, sorted. Defensive on both sides: an order
/// naming an absent key contributes nothing, and a key no order names is
/// never dropped.
fn names_in_order(merged: &BTreeMap<String, Json>, declared: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(merged.len());
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for name in declared {
        if merged.contains_key(name) && seen.insert(name.clone()) {
            out.push(name.clone());
        }
    }
    for name in merged.keys() {
        if seen.insert(name.clone()) {
            out.push(name.clone());
        }
    }
    out
}

/// Resolve the activation order: constraints, then bands, then the
/// feature's position in the merged map.
///
/// `before`/`after` take a feature name or a list of them and are
/// SATISFIED VACUOUSLY when the named feature is absent - `after: 'test'`
/// loads fine in a project with no test feature, which is sdkgen's
/// `__after__` behaviour kept rather than reinvented.
///
/// Constraints beat bands; bands break ties no constraint decides;
/// remaining ties break by DECLARATION POSITION - `declared`, which this
/// port's map type cannot supply and every caller therefore passes (an
/// empty slice falls back to bytewise key order). So the result is a
/// stable topological sort with no alphabetical accident left in it.
///
/// Returns OUTERMOST FIRST, which is the array form the constructor takes
/// and the direction plugin's chain composes in.
pub fn resolve_order(merged: &Json, declared: &[String]) -> Result<Vec<Ordered>, StationError> {
    let empty = BTreeMap::new();
    let entries = match merged {
        Json::Map(entries) => entries,
        _ => &empty,
    };

    let names: Vec<String> = names_in_order(entries, declared)
        .into_iter()
        .filter(|name| active(&entries[name]))
        .collect();

    let pos: BTreeMap<&str, usize> = names
        .iter()
        .enumerate()
        .map(|(at, name)| (name.as_str(), at))
        .collect();

    let mut band: BTreeMap<&str, f64> = BTreeMap::new();
    for name in &names {
        let explicit = jget(&entries[name], "order")
            .and_then(|order| jget(order, "band"))
            .and_then(|found| match found {
                Json::Num(num) => Some(*num),
                _ => None,
            });
        band.insert(name.as_str(), explicit.unwrap_or_else(|| default_band(name)));
    }

    // edges: from OUTER to INNER. `after: X` means "further in than X".
    let mut inner: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for name in &names {
        inner.insert(name.as_str(), BTreeSet::new());
    }

    for name in &names {
        let order = match jget(&entries[name], "order") {
            Some(order @ Json::Map(_)) => order,
            _ => continue,
        };
        // Vacuous when absent: an unknown name is not an error here.
        for other in listof(jget(order, "after")) {
            if let Some(set) = inner.get_mut(other.as_str()) {
                set.insert(name.as_str());
            }
        }
        for other in listof(jget(order, "before")) {
            // `names` owns the strings the edge sets borrow, so the
            // target is looked up there rather than in `other`.
            if let Some(target) = names.iter().find(|one| one.as_str() == other.as_str()) {
                if let Some(set) = inner.get_mut(name.as_str()) {
                    set.insert(target.as_str());
                }
            }
        }
    }

    let mut indeg: BTreeMap<&str, usize> = names.iter().map(|name| (name.as_str(), 0)).collect();
    for name in &names {
        for one in &inner[name.as_str()] {
            *indeg.get_mut(one).unwrap() += 1;
        }
    }

    // Kahn, picking the LOWEST BAND first (outermost), then declaration
    // position - so ties break the same way in every port.
    let mut ready: Vec<&str> = names
        .iter()
        .map(|name| name.as_str())
        .filter(|name| 0 == indeg[name])
        .collect();
    let mut out: Vec<Ordered> = Vec::new();

    while !ready.is_empty() {
        ready.sort_by(|a, b| {
            band[a]
                .partial_cmp(&band[b])
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(pos[a].cmp(&pos[b]))
        });
        let name = ready.remove(0);
        out.push(Ordered {
            name: name.to_string(),
            band: band[name],
            entry: entries[name].clone(),
        });
        let kids: Vec<&str> = inner[name].iter().copied().collect();
        for one in kids {
            let deg = indeg.get_mut(one).unwrap();
            *deg -= 1;
            if 0 == *deg {
                ready.push(one);
            }
        }
    }

    if out.len() != names.len() {
        let mut stuck: Vec<String> = names
            .iter()
            .filter(|name| !out.iter().any(|row| &row.name == *name))
            .cloned()
            .collect();
        stuck.sort();
        return Err(StationError::new(
            "station_feature_order",
            format!(
                "feature ordering constraints form a cycle among [{}]",
                stuck.join(", ")
            ),
        ));
    }

    Ok(out)
}

/// A `before`/`after` value: a single name or a list of them, stringified.
fn listof(val: Option<&Json>) -> Vec<String> {
    match val {
        None | Some(Json::Null) => Vec::new(),
        Some(Json::List(items)) => items.iter().map(|item| item.text()).collect(),
        Some(other) => vec![other.text()],
    }
}

/// Station's own position is PINNED and not orderable (§8.4): an order
/// that moves `station` away from immediately-outside-the-base is
/// REJECTED, not honoured.
///
/// THE PIN IS `innermost`, AND THE SPELLING MATTERS. A chain composes
/// with the FIRST binding outermost, so a pin written in sort terms -
/// "station first" - would place every other wrapper between the adapter
/// and the base: the exact inversion of the invariant, and one that would
/// leave station's wire-truth events observing the wrong boundary while
/// still looking ordered.
pub fn check_pin(ordered: &[Ordered]) -> Result<(), StationError> {
    let at = match ordered.iter().position(|row| "station" == row.name) {
        Some(at) => at as i64,
        None => return Ok(()),
    };

    let base = ordered.iter().position(|row| "test" == row.name);
    // station must be the innermost wrapper: last, or immediately outside
    // the base-transport feature when one is active.
    let want = match base {
        None => ordered.len() as i64 - 1,
        Some(base) => base as i64 - 1,
    };
    if at != want {
        return Err(StationError::new(
            "station_feature_order",
            "an ordering would move `station` away from immediately outside \
             the base transport; its position is pinned innermost and is not \
             orderable (§8.4)",
        ));
    }
    Ok(())
}

/// Just the names of a resolved order, outermost first.
pub fn feature_names(ordered: &[Ordered]) -> Vec<String> {
    ordered.iter().map(|row| row.name.clone()).collect()
}

/// Compose the merged map into the ORDERED ARRAY FORM the generated
/// constructor takes. No new seam: it is what the binding already does
/// for station's own placement, with more in it. RESERVED_KEYS are not
/// options and are never passed through.
pub fn compose_features(ordered: &[Ordered]) -> Vec<Json> {
    ordered
        .iter()
        .map(|row| {
            let mut out: BTreeMap<String, Json> = BTreeMap::new();
            out.insert("name".to_string(), Json::Str(row.name.clone()));
            out.insert("active".to_string(), Json::Bool(true));
            if let Json::Map(fields) = &row.entry {
                for (key, val) in fields.iter() {
                    if RESERVED_KEYS.contains(&key.as_str()) {
                        continue;
                    }
                    out.insert(key.clone(), val.clone());
                }
            }
            Json::Map(out)
        })
        .collect()
}

// ---------------------------------------------------------------------
// §8.5 - the checker, derived from the descriptor
// ---------------------------------------------------------------------

/// One §8.5 finding. COLLECTED, never raised: the callers own the throw.
#[derive(Clone, Debug)]
pub struct Fault {
    pub code: String,
    pub feature: String,
    pub key: Option<String>,
    pub message: String,
}

/// Check a merged feature map against the SDK'S OWN DECLARATION.
///
/// The schema arrives with the FACTORY rather than with a live client
/// (§6.2), so this needs no construction and no network - which is what
/// lets `check()` run it for every instance in CI, and what lets
/// `build()` run it before every construction.
///
/// Derived from the descriptor, NEVER hand-written, so it cannot drift:
/// when a feature gains an option, the next regeneration teaches station
/// about it with no station change.
///
/// SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED ONLY,
/// and that limit is real and deliberate: an empty list default says
/// nothing reliable about its element type and a nested map default says
/// nothing about its value shapes.
pub fn check_features(merged: &Json, descriptor: &Json) -> Vec<Fault> {
    let mut faults: Vec<Fault> = Vec::new();

    let mut byname: BTreeMap<String, Json> = BTreeMap::new();
    if let Some(Json::List(declared)) = jget(descriptor, "features") {
        for row in declared {
            byname.insert(crate::jsonx::jstr(row, "name"), row.clone());
        }
    }
    let declarednames: Vec<String> = byname.keys().cloned().collect();

    let empty = BTreeMap::new();
    let entries = match merged {
        Json::Map(entries) => entries,
        _ => &empty,
    };

    // BTreeMap iterates in sorted order, which is the order §8.5 wants.
    for (name, entry) in entries.iter() {
        let spec = match byname.get(name) {
            Some(spec) => spec,
            None => {
                faults.push(Fault {
                    code: "station_feature_unknown".to_string(),
                    feature: name.clone(),
                    key: None,
                    message: format!(
                        "the SDK has no feature \"{}\"; it declares [{}]",
                        name,
                        declarednames.join(", ")
                    ),
                });
                continue;
            }
        };

        let fields = match entry {
            Json::Map(fields) => fields,
            _ => continue,
        };
        let defaults = jmap(spec, "options").cloned().unwrap_or_default();
        let defaultkeys: Vec<String> = defaults.keys().cloned().collect();

        for (key, val) in fields.iter() {
            if RESERVED_KEYS.contains(&key.as_str()) {
                continue;
            }

            let want = match defaults.get(key) {
                Some(found) => found,
                None => {
                    // THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is
                    // accepted and silently ignored today, because the
                    // SDK's own feature spec is `$OPEN` per feature so
                    // the SDK cannot catch it and nothing else looks.
                    faults.push(Fault {
                        code: "station_feature_option".to_string(),
                        feature: name.clone(),
                        key: Some(key.clone()),
                        message: format!(
                            "feature \"{}\" declares no option \"{}\"; it declares [{}]",
                            name,
                            key,
                            defaultkeys.join(", ")
                        ),
                    });
                    continue;
                }
            };

            let wantkind = featurekind(Some(want));
            let gotkind = featurekind(Some(val));
            if wantkind != gotkind {
                faults.push(Fault {
                    code: "station_feature_option".to_string(),
                    feature: name.clone(),
                    key: Some(key.clone()),
                    message: format!(
                        "feature \"{}\" option \"{}\" expects {}, but found {}: {}",
                        name,
                        key,
                        wantkind,
                        gotkind,
                        canonical_serialize(val)
                    ),
                });
            }
        }
    }

    faults
}

/// Every fault's message, joined - what the callers raise.
pub fn fault_messages(faults: &[Fault]) -> String {
    faults
        .iter()
        .map(|fault| fault.message.clone())
        .collect::<Vec<String>>()
        .join("; ")
}

/// The FEATURE kindof. NOT the same function as the shape's
/// (`shape::shapekind`) - they disagree on numbers and maps deliberately,
/// and unifying them would make one of the two message sets wrong.
fn featurekind(val: Option<&Json>) -> &'static str {
    match val {
        None | Some(Json::Null) => "null",
        Some(Json::List(_)) => "list",
        Some(Json::Num(_)) => "number",
        Some(Json::Map(_)) => "map",
        Some(Json::Bool(_)) => "boolean",
        Some(Json::Str(_)) => "string",
    }
}
