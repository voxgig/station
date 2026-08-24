// RUN: make test  (from the port root, after `make vendor`)
// RUN-SOME: cd corpus && cargo test <name>
//
// Both name this SEPARATE package deliberately: the suite lives outside
// the published crate (omni register 4.13), so `cargo test` from the
// port root runs only the library's unit tests - a green that ran no
// conformance at all.
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the generated-consumer validation
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present. Mirrors typescript/test/conform.test.ts.
//
// THE OPT-IN SURFACE IS THE `drivers()` TABLE, AND THE ONLY ONE. The
// per-section runs are derived from it, so a section named there cannot
// silently not run; `PENDING` is the other half - a recorded decision
// not to run a section, with the reason in the source; and
// `sections_covered` asserts the two together cover exactly what the
// corpus carries. Rust has no dynamic test registry, so the table is a
// static array iterated by the runner rather than a test per section -
// the same two properties, the shape the design's porting note names for
// c, cpp, rust, go and java.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;

use voxgig_omni::{make_runner, Json as OJson, Provider, Subject, NULLMARK};

use voxgig_station::{
    canonical_serialize, check_pin, envtoken, feature_names, feature_sources, instance_ref,
    is_known_code, merge_features, normalize_config, normalize_descriptor, placeholder_for,
    resolve_order, resolve_profile, secretname_default, validate_config, Json,
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

// A denulled entry field, as an OPTIONAL node: absent and null are the
// same thing to a driver that reads `base?.feature`.
fn o2sopt(val: &OJson) -> Option<Json> {
    match o2s(val) {
        Json::Null => None,
        other => Some(other),
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

// The sections this port deliberately does NOT run, with the reason - an
// entry here is a DECISION, not an omission.
//
// `profile` pins the pre-Stage-1 `plugin` grammar, which this port no
// longer speaks. It stays in the corpus for the ports that have not
// crossed the rename yet and is deleted when the last one does - see
// spec/README.md. Everything it pins is restated in the sdk/api grammar
// the `instance` section runs.
const PENDING: [(&str, &str); 1] = [(
    "profile",
    "pre-rename plugin grammar; superseded by the instance section",
)];

// One driver per section this port RUNS, keyed by the corpus section
// name. THE TESTS ARE DERIVED FROM THIS TABLE, never written out by
// hand, so a section listed here cannot silently fail to execute - and
// sections_covered closes the other direction.
fn drivers() -> Vec<(&'static str, Subject)> {
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

    let canonical: Subject =
        Rc::new(|args: &[OJson]| Ok(OJson::Str(canonical_serialize(&o2s(&args[0])))));

    // Normalize, then validate (design §4.2). The entry is a RAW config
    // in, and either the normalized output or the expected error out -
    // the two steps are one pipeline, and a port that splits them is
    // free to validate the wrong form.
    let config: Subject = Rc::new(|args: &[OJson]| {
        let raw = o2s(&args[0]);
        match validate_config(&normalize_config(&raw)) {
            Ok(normalized) => Ok(s2o(&normalized)),
            Err(err) => Err(err.to_string()),
        }
    });

    // The §3.3 merge, and the whole of this port's profile contract.
    let instance: Subject = Rc::new(|args: &[OJson]| {
        let config = o2sopt(&args[0].get("config"));
        let name = args[0]
            .get("profile")
            .asstr()
            .unwrap_or("default")
            .to_string();
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

    // §6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
    // rather than driver-shaped even though it decides a registry key.
    let instanceref: Subject = Rc::new(|args: &[OJson]| {
        let api = args[0].get("api").asstr().unwrap_or("").to_string();
        let opts = o2s(&args[0].get("opts"));
        match instance_ref(&api, &opts) {
            Ok(reference) => Ok(OJson::Str(reference)),
            Err(err) => Err(err.to_string()),
        }
    });

    // §8's pure half (design §10.1): the three-level merge with its depth
    // boundary, and the §8.4 order resolution. One driver, two entry
    // shapes - `merged` selects the resolver, anything else the merge -
    // because a port that guessed from looser cues would run the wrong
    // subject on a mistyped entry.
    //
    // The resolver takes the declared order EXPLICITLY (see
    // src/feature.rs), and an omni map is a BTreeMap, so there is no
    // authored order to hand it: the empty slice takes the documented
    // bytewise fallback.
    let feature: Subject = Rc::new(|args: &[OJson]| {
        if let Some(merged) = o2sopt(&args[0].get("merged")) {
            let ordered = resolve_order(&merged, &[]).map_err(|err| err.to_string())?;
            check_pin(&ordered).map_err(|err| err.to_string())?;
            return Ok(OJson::List(
                feature_names(&ordered)
                    .into_iter()
                    .map(OJson::Str)
                    .collect(),
            ));
        }
        let base = o2sopt(&args[0].get("base"));
        let overlay = o2sopt(&args[0].get("overlay"));
        let api = args[0].get("api").asstr().unwrap_or("").to_string();
        let reference = args[0].get("ref").asstr().unwrap_or("").to_string();
        let sources = feature_sources(base.as_ref(), overlay.as_ref(), &api, &reference);
        Ok(s2o(&merge_features(&sources)))
    });

    let errors: Subject =
        Rc::new(|args: &[OJson]| Ok(OJson::Bool(is_known_code(args[0].asstr().unwrap_or("")))));

    vec![
        ("secretname", secretname),
        ("placeholder", placeholder),
        ("descriptor", descriptor),
        ("descriptorwarnings", descriptorwarnings),
        ("canonical", canonical),
        ("config", config),
        ("instance", instance),
        ("instanceref", instanceref),
        ("feature", feature),
        ("errors", errors),
    ]
}

#[test]
fn station_conformance() {
    let pack = runpack();

    for (name, subject) in drivers() {
        // A renamed section must not quietly match nothing.
        let set = pack.set(name);
        assert!(
            !matches!(set, OJson::Absent),
            "corpus section missing: {}",
            name
        );
        if let Err(err) = pack.runset(&set, Some(&subject)) {
            panic!("group {}: {}", name, err);
        }
    }
}

// Section completeness: the sections RUN plus the explicit PENDING list
// must exactly cover what spec/station.json carries. A section added to
// the corpus and not picked up here fails loudly instead of silently not
// running, and a section removed or renamed while this port still lists
// it fails too - so a stale driver or a stale pending pin is caught
// rather than rotting.
//
// The corpus file is read as RAW JSON here, not through the omni runner:
// the runner resolves and normalizes a named section, and would hide a
// section it never resolved.
#[test]
fn sections_covered() {
    let text = std::fs::read_to_string(specfile()).expect("spec readable");
    let spec = voxgig_sekreto::json::parse(&text).expect("spec parses");

    let sections = match spec.get("primary").and_then(|p| p.get("station")) {
        Some(Json::Map(entries)) => entries,
        _ => panic!("station: spec has no primary.station"),
    };
    // BTreeMap keys iterate sorted, which is the order the comparison
    // wants on both sides.
    let present: Vec<String> = sections.keys().cloned().collect();

    let mut covered: Vec<String> = drivers()
        .iter()
        .map(|(name, _)| name.to_string())
        .chain(PENDING.iter().map(|(name, _)| name.to_string()))
        .collect();
    covered.sort();

    assert_eq!(
        present, covered,
        "sections in spec/station.json vs sections run or pinned pending"
    );
}

// The one place station's and sekreto's grammars meet (design §5.1): the
// corpus pins secretname -> envkey through sekreto's OWN envkey, never a
// restatement.
fn voxgig_sekreto_envkey(name: &str) -> String {
    voxgig_sekreto::envkey(name, "").expect("valid secret name")
}
