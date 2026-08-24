//! Descriptor v1 (design §4): a view over the SDK's embedded config,
//! normalized - never a second model. A port of
//! typescript/src/descriptor.ts, which is canonical.

use std::collections::BTreeMap;

use voxgig_sekreto::Json;

use crate::jsonx::{jget, jobj, jtext};

/// The ONLY way to build an env-var token in station, mirroring sdkgen's
/// packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
/// `secretname` corpus section pins the round-trip against sekreto's
/// envkey() and sdkgen's envName() - the one place three grammars meet.
pub fn envtoken(name: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for head in name.chars() {
        let up = head.to_ascii_uppercase();
        if up.is_ascii_uppercase() || up.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push('_');
            }
            gap = false;
            out.push(up);
        } else {
            gap = true;
        }
    }
    out
}

/// The default sekreto name for a plugin (design §5.1): envtoken(slug)
/// lowercased, plus '.apikey'. sekreto's envkey() then yields exactly the
/// env var the SDK's README documents: gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
pub fn secretname_default(slug: &str) -> String {
    format!("{}.apikey", envtoken(slug).to_lowercase())
}

/// Best-effort slug from a camel name, for SDKs whose embedded config
/// predates main.slug (design §4 legacy sentinels). The hyphen caveat is
/// real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo' -
/// callers surface a warning event when this path is taken.
fn legacy_slug(name: &str) -> String {
    name.to_lowercase()
}

/// A string field the way JS `String(x || '')` reads it: strings verbatim,
/// absent/null/empty -> ''.
fn strdef(val: &Json, key: &str) -> String {
    match jget(val, key) {
        Some(Json::Str(text)) => text.clone(),
        _ => String::new(),
    }
}

/// A carried field with a sentinel default: present (and non-null) values
/// stringify, absent/null takes the sentinel (design §4 legacy sentinels).
fn sentinel(val: &Json, key: &str, dflt: &str) -> String {
    match jget(val, key) {
        Some(Json::Null) | None => dflt.to_string(),
        Some(found) => found.text(),
    }
}

/// Normalize a generated SDK's embedded config into descriptor v1
/// (design §4). The config is the one every SDK carries (main / feature /
/// options / entity); the descriptor is a VIEW over it. `active_features`
/// is the client's options.feature map. Returns the descriptor plus any
/// legacy warnings.
pub fn normalize_descriptor(config: &Json, active_features: &Json) -> (Json, Vec<String>) {
    let mut warnings: Vec<String> = Vec::new();

    let empty = Json::Map(BTreeMap::new());
    let main = jget(config, "main").unwrap_or(&empty);
    let options = jget(config, "options").unwrap_or(&empty);

    let name = strdef(main, "name");
    let mut slug = strdef(main, "slug");
    if slug.is_empty() {
        slug = legacy_slug(&name);
        warnings.push(format!(
            "descriptor: legacy config has no main.slug; derived \"{}\" from \
             the camel name - hyphens in the original name are lost",
            slug
        ));
    }

    let version = sentinel(main, "version", "0.0.0");
    let target = sentinel(main, "target", "unknown");

    let mut server: Vec<Json> = Vec::new();
    if let Some(Json::Map(svr)) = jget(options, "server") {
        for (key, val) in svr.iter() {
            server.push(jobj(vec![
                ("name", jtext(key.clone())),
                ("value", jtext(val.text())),
            ]));
        }
    }

    let auth_cfg = jget(options, "auth");
    let auth_active = matches!(auth_cfg, Some(found) if !matches!(found, Json::Null));
    let auth_prefix = match auth_cfg {
        Some(found) if auth_active => strdef(found, "prefix"),
        _ => String::new(),
    };
    let auth = jobj(vec![
        ("active", Json::Bool(auth_active)),
        ("prefix", jtext(auth_prefix)),
        ("secretname", jtext(secretname_default(&slug))),
    ]);

    let mut entities = BTreeMap::new();
    if let Some(Json::Map(entdefs)) = jget(config, "entity") {
        for (ename, edef) in entdefs.iter() {
            let mut fields = BTreeMap::new();
            if let Some(Json::List(flist)) = jget(edef, "fields") {
                for field in flist {
                    let fname = strdef(field, "name");
                    if fname.is_empty() {
                        continue;
                    }
                    let mut kind = strdef(field, "kind");
                    if kind.is_empty() {
                        kind = strdef(field, "type");
                    }
                    fields.insert(fname, jobj(vec![("kind", jtext(kind))]));
                }
            }

            let mut ops = BTreeMap::new();
            if let Some(Json::Map(opdefs)) = jget(edef, "op") {
                for (opname, opdef) in opdefs.iter() {
                    let mut points: Vec<Json> = Vec::new();
                    if let Some(Json::List(plist)) = jget(opdef, "points") {
                        for pdef in plist {
                            if matches!(pdef, Json::Null) {
                                continue;
                            }
                            let mut path = strdef(pdef, "orig");
                            if path.is_empty() {
                                path = strdef(pdef, "path");
                            }
                            let mut params: Vec<Json> = Vec::new();
                            if let Some(Json::List(parts)) = jget(pdef, "parts") {
                                for part in parts {
                                    if let Json::Str(text) = part {
                                        if let Some(stripped) = text.strip_prefix(':') {
                                            params.push(jtext(stripped));
                                        }
                                    }
                                }
                            }
                            let mut point = vec![
                                ("method", jtext(strdef(pdef, "method"))),
                                ("path", jtext(path)),
                                ("params", Json::List(params)),
                            ];
                            match jget(pdef, "select") {
                                Some(Json::Null) | None => {}
                                Some(select) => point.push(("select", select.clone())),
                            }
                            points.push(jobj(point));
                        }
                    }
                    ops.insert(opname.clone(), jobj(vec![("points", Json::List(points))]));
                }
            }

            let mut entity = BTreeMap::new();
            entity.insert("fields".to_string(), Json::Map(fields));
            entity.insert("ops".to_string(), Json::Map(ops));
            entities.insert(ename.clone(), Json::Map(entity));
        }
    }

    // §8.5: the features list gains `options` and `transport`, because it
    // was throwing away what the SDK already embeds -
    // `config.feature[name].options` is the feature's own declared key set
    // WITH TYPED DEFAULTS, which is the schema §8.5 validates against, and
    // `transport` is the role §8.4 orders by.
    //
    // Both are already inside the SDK; the descriptor stops discarding
    // them. ADDITIVE, so descriptor v1 consumers are unaffected and the
    // `descriptor` corpus section still passes unchanged.
    //
    // `transport` is CARRIED rather than inferred: the obvious signal, an
    // empty `hook: {}`, is wrong for station, which both wraps AND
    // dispatches hooks. Absent until sdkgen emits it, and §8.4's role
    // checks degrade to nothing until then rather than guessing.
    let mut features: Vec<Json> = Vec::new();
    if let Some(Json::Map(fdefs)) = jget(config, "feature") {
        for (fname, fdef) in fdefs.iter() {
            let active = matches!(
                jget(active_features, fname).and_then(|f| jget(f, "active")),
                Some(Json::Bool(true))
            );
            let mut row = vec![
                ("name", jtext(fname.clone())),
                ("active", Json::Bool(active)),
            ];
            if let Some(fopts @ Json::Map(_)) = jget(fdef, "options") {
                row.push(("options", fopts.clone()));
            }
            match jget(fdef, "transport") {
                Some(Json::Null) | None => {}
                Some(found) => {
                    let text = found.text();
                    if !text.is_empty() {
                        row.push(("transport", jtext(text)));
                    }
                }
            }
            features.push(jobj(row));
        }
    }

    let descriptor = jobj(vec![
        ("station", Json::Num(1.0)),
        ("name", jtext(name)),
        ("slug", jtext(slug.clone())),
        ("envtoken", jtext(envtoken(&slug))),
        ("version", jtext(version)),
        ("target", jtext(target)),
        ("base", jtext(strdef(options, "base"))),
        ("server", Json::List(server)),
        ("auth", auth),
        ("entities", Json::Map(entities)),
        ("features", Json::List(features)),
    ]);

    (descriptor, warnings)
}

/// Canonical serialization (design §4): UTF-8, object keys sorted
/// bytewise, no insignificant whitespace, minimal JSON escaping. The
/// proxy dedupes registrations by a hash of this, so every language must
/// produce identical bytes - the `canonical-serialize` corpus section
/// carries the adversarial cases. `BTreeMap` already iterates keys in
/// bytewise (UTF-8) order, which is the required order.
pub fn canonical_serialize(val: &Json) -> String {
    match val {
        Json::Null => "null".to_string(),
        Json::Bool(flag) => flag.to_string(),
        Json::Num(num) => canon_num(*num),
        Json::Str(text) => canon_quote(text),
        Json::List(items) => {
            let parts: Vec<String> = items.iter().map(canonical_serialize).collect();
            format!("[{}]", parts.join(","))
        }
        Json::Map(entries) => {
            let parts: Vec<String> = entries
                .iter()
                .map(|(key, entry)| format!("{}:{}", canon_quote(key), canonical_serialize(entry)))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

/// Numbers the way JSON.stringify writes them: integers with no trailing
/// `.0` (covering the full f64-exact range), everything else shortest
/// round-trip.
fn canon_num(num: f64) -> String {
    if num.is_finite() && num == num.trunc() && num.abs() < 9.0e18 {
        return format!("{}", num as i64);
    }
    format!("{}", num)
}

/// Minimal JSON escaping, byte-for-byte what JSON.stringify emits: quote,
/// backslash, the short escapes, `\u00xx` for remaining controls, and
/// everything else - non-ASCII included - raw UTF-8.
fn canon_quote(text: &str) -> String {
    let mut out = String::from("\"");
    for head in text.chars() {
        match head {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ if (head as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", head as u32)),
            _ => out.push(head),
        }
    }
    out.push('"');
    out
}
