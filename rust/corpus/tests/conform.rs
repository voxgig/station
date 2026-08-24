// RUN: make test  (cargo test, after `make vendor`)
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the generated-consumer validation
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present. Mirrors typescript/test/conform.test.ts.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;

use voxgig_omni::{make_runner, Json as OJson, Provider, Subject, NULLMARK};

use voxgig_station::{
    canonical_serialize, envtoken, is_known_code, normalize_descriptor, placeholder_for,
    resolve_profile, secretname_default, Json,
};

// Find the shared spec by walking up from this crate (the station repo
// keeps it at spec/station.json - the omni ports' own convention).
fn specfile() -> String {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for _step in 0..8 {
        let cand = dir.join("spec").join("station.json");
        if cand.exists() {
            return cand.to_string_lossy().to_string();
        }
        dir = match dir.parent() {
            Some(parent) => parent.to_path_buf(),
            None => break,
        };
    }
    panic!("station: spec not found: station.json");
}

// omni Json -> station Json. Spec nulls arrive as omni's NULLMARK
// sentinel; restore them so subjects see what the spec means (the
// canonical test's denull, applied on the way across).
fn o2s(val: &OJson) -> Json {
    match val {
        OJson::Absent | OJson::Null => Json::Null,
        OJson::Bool(flag) => Json::Bool(*flag),
        OJson::Num(num) => Json::Num(*num),
        OJson::Str(text) if NULLMARK == text => Json::Null,
        OJson::Str(text) => Json::Str(text.clone()),
        OJson::List(items) => Json::List(items.iter().map(o2s).collect()),
        OJson::Map(entries) => {
            let mut out = BTreeMap::new();
            for (key, entry) in entries.iter() {
                out.insert(key.clone(), o2s(entry));
            }
            Json::Map(out)
        }
    }
}

// station Json -> omni Json, for result comparison.
fn s2o(val: &Json) -> OJson {
    match val {
        Json::Null => OJson::Null,
        Json::Bool(flag) => OJson::Bool(*flag),
        Json::Num(num) => OJson::Num(*num),
        Json::Str(text) => OJson::Str(text.clone()),
        Json::List(items) => OJson::List(items.iter().map(s2o).collect()),
        Json::Map(entries) => {
            let mut out = std::collections::BTreeMap::new();
            for (key, entry) in entries.iter() {
                out.insert(key.clone(), s2o(entry));
            }
            OJson::Map(out)
        }
    }
}

fn runpack() -> voxgig_omni::RunPack {
    let runner = make_runner(specfile().as_str(), Provider::default()).expect("runner");
    runner.runner("station", None).expect("spec")
}

#[test]
fn station_conformance() {
    let pack = runpack();

    let secretname: Subject = Rc::new(|args: &[OJson]| {
        let slug = args[0].get("slug").asstr().unwrap_or("").to_string();
        let name = secretname_default(&slug);
        let envkey = voxgig_sekreto_envkey(&name);
        Ok(OJson::map(vec![
            ("envtoken", OJson::Str(envtoken(&slug))),
            ("secretname", OJson::Str(name)),
            ("envkey", OJson::Str(envkey)),
        ]))
    });

    let placeholder: Subject = Rc::new(|args: &[OJson]| {
        Ok(OJson::Str(placeholder_for(args[0].asstr().unwrap_or(""))))
    });

    let descriptor: Subject = Rc::new(|args: &[OJson]| {
        let config = o2s(&args[0].get("config"));
        let feature = o2s(&args[0].get("feature"));
        let (desc, _warnings) = normalize_descriptor(&config, &feature);
        Ok(s2o(&desc))
    });

    let descriptorwarnings: Subject = Rc::new(|args: &[OJson]| {
        let config = o2s(&args[0].get("config"));
        let feature = o2s(&args[0].get("feature"));
        let (_desc, warnings) = normalize_descriptor(&config, &feature);
        Ok(OJson::Num(warnings.len() as f64))
    });

    let canonical: Subject = Rc::new(|args: &[OJson]| {
        Ok(OJson::Str(canonical_serialize(&o2s(&args[0]))))
    });

    // The §3.3 merge, and the whole of this port's profile contract.
    //
    // The `profile` section is NOT run: it pins the pre-Stage-1 `plugin`
    // grammar, which this port no longer speaks. It stays in the corpus
    // for the ports that have not crossed the rename yet and is deleted
    // when the last one does - see spec/README.md.
    let instance: Subject = Rc::new(|args: &[OJson]| {
        let config_in = args[0].get("config");
        let config = match &config_in {
            OJson::Absent | OJson::Null => None,
            OJson::Str(text) if NULLMARK == text => None,
            other => Some(o2s(other)),
        };
        let name = args[0].get("profile").asstr().unwrap_or("default").to_string();
        match resolve_profile(config.as_ref(), &name) {
            Err(err) => Err(err.to_string()),
            Ok(resolved) => {
                let mut api = std::collections::BTreeMap::new();
                for (slug, val) in resolved.api.iter() {
                    api.insert(slug.clone(), s2o(val));
                }
                let mut sdk = std::collections::BTreeMap::new();
                for (reference, val) in resolved.sdk.iter() {
                    sdk.insert(reference.clone(), s2o(val));
                }
                Ok(OJson::map(vec![
                    ("name", OJson::Str(resolved.name)),
                    (
                        "providers",
                        OJson::List(resolved.providers.iter().map(s2o).collect()),
                    ),
                    ("api", OJson::Map(api)),
                    ("sdk", OJson::Map(sdk)),
                ]))
            }
        }
    });

    let errors: Subject = Rc::new(|args: &[OJson]| {
        Ok(OJson::Bool(is_known_code(args[0].asstr().unwrap_or(""))))
    });

    let groups: Vec<(&str, &Subject)> = vec![
        ("secretname", &secretname),
        ("placeholder", &placeholder),
        ("descriptor", &descriptor),
        ("descriptorwarnings", &descriptorwarnings),
        ("canonical", &canonical),
        ("instance", &instance),
        ("errors", &errors),
    ];

    for (name, subject) in groups {
        if let Err(err) = pack.runset(&pack.set(name), Some(subject)) {
            panic!("group {}: {}", name, err);
        }
    }
}

// The one place station's and sekreto's grammars meet (design §5.1): the
// corpus pins secretname -> envkey through sekreto's OWN envkey, never a
// restatement.
fn voxgig_sekreto_envkey(name: &str) -> String {
    voxgig_sekreto::envkey(name, "").expect("valid secret name")
}
