// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the voxgig_station library
// (station design 2); station::bind resolves the ambient station
// (Station::open - rust options are pure data, so no handle rides them;
// station design 3.1), verifies wrap position, and registers. No station
// open -> None, and the feature is an inert no-op. This file only
// translates the generated SDK's concrete types (Value, Context,
// FetcherFn) into the library's BindSpec/prepare seams - never restate a
// binding rule here. The one physical duty the type boundary leaves on
// this side is the copy-on-inject clone (station design 5.3): the
// fetchdef is deep-cloned BEFORE the injected header set is applied, so
// the object graph reachable from ctx/spec/ctrl.explain keeps only the
// placeholder, ever.

use std::any::Any;
use std::collections::BTreeMap;
use std::rc::Rc;

use voxgig_station as station;
use voxgig_station::Json;

use crate::core::context::Context;
use crate::core::error::ProjectNameError;
use crate::core::helpers::{get_str, getp, getpath, setp};
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub struct StationFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    binding: Option<Rc<station::Binding>>,
}

impl StationFeature {
    pub fn new() -> StationFeature {
        StationFeature {
            name: "station".to_string(),
            active: true,
            add_opts: None,
            binding: None,
        }
    }
}

impl Feature for StationFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, ctx: &Rc<Context>, options: &Value) {
        self.active = fopt_bool(options, "active", false);
        if !self.active {
            return;
        }

        let client = match ctx.client.borrow().clone() {
            Some(client) => client,
            None => return,
        };
        let utility = ctx.util();

        // The client's feature list by name, in init order - the wrap
        // position guard's input (station design 3.3). The one entry that
        // cannot be borrowed is this feature itself, mid-init under
        // feature_init's borrow_mut - its name is by definition ours.
        let names: Vec<String> = client
            .features
            .borrow()
            .iter()
            .map(|f| match f.try_borrow() {
                Ok(feature) => feature.name(),
                Err(_) => self.name.clone(),
            })
            .collect();

        let opts = ctx.options.borrow().clone();
        let config = ctx.config.borrow().clone();

        let bound = match station::bind(station::BindSpec {
            client: client.clone() as Rc<dyn Any>,
            config: value_json(&config),
            feature_names: names,
            active_features: value_json(&getp(&opts, "feature")),
            feature_opts: value_json(options),
            options_base: get_str(&opts, "base").unwrap_or_default(),
            config_base: match getpath(&["options", "base"], &config) {
                Value::Str(base) => base,
                _ => String::new(),
            },
            resident_apikey: get_str(&opts, "apikey").unwrap_or_default(),
        }) {
            Some(bound) => bound,
            None => return,
        };

        // Apply the binding's mutation set to the live options map (shared
        // with the client and every context): the profile base (station
        // design 3.5) and the credential placeholder - prepare_auth then
        // emits the placeholder, and the transport swaps in the real value
        // at send time, below every recording feature.
        if let Some(base) = &bound.base {
            setp(&opts, "base", Value::str(base.clone()));
        }
        if let Some(placeholder) = &bound.placeholder {
            setp(&opts, "apikey", Value::str(placeholder.clone()));
        }

        let binding = bound.binding.clone();
        self.binding = Some(binding.clone());

        // Wrap the transport: clone-and-replace like every transport
        // feature (retry/proxy). Position = init order, already verified.
        let inner: FetcherFn = utility.fetcher.borrow().clone();
        *utility.fetcher.borrow_mut() = Rc::new(move |ctx2, fullurl, fetchdef| {
            station_transport(&binding, &inner, ctx2, fullurl, fetchdef)
        });
    }

    // Hook bridge (station design 3 item 3): operation semantics
    // correlated with the http events via the op context's own id.

    fn pre_point(&mut self, ctx: &Rc<Context>) {
        if let Some(binding) = &self.binding {
            binding.op_start(&ctx.id);
        }
    }

    fn pre_done(&mut self, ctx: &Rc<Context>) {
        if let Some(binding) = &self.binding {
            let (entity, opname) = op_identity(ctx);
            binding.op_done(&ctx.id, &entity, &opname, &outcome_of(ctx));
        }
    }

    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        if let Some(binding) = &self.binding {
            let (entity, opname) = op_identity(ctx);
            binding.op_done(&ctx.id, &entity, &opname, "unexpected");
        }
    }
}

// The transport middleware shell: extract what the library's per-request
// decisions need, apply its plan, report the outcome for the event
// stream. All decisions (require, hosts policy, injection, event shapes)
// are the library's.
fn station_transport(
    binding: &Rc<station::Binding>,
    inner: &FetcherFn,
    ctx: &Rc<Context>,
    fullurl: &str,
    fetchdef: &Value,
) -> Result<Value, ProjectNameError> {
    let live = match ctx.client.borrow().clone() {
        Some(client) => "live" == *client.mode.borrow(),
        None => false,
    };
    let corr = binding.corr_of(&ctx.id);

    let mut headers: BTreeMap<String, String> = BTreeMap::new();
    if let Value::Map(hm) = getp(fetchdef, "headers") {
        for (name, val) in hm.borrow().iter() {
            if let Value::Str(text) = val {
                headers.insert(name.clone(), text.clone());
            }
        }
    }

    let method = get_str(fetchdef, "method")
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "GET".to_string());

    let plan = match binding.prepare(corr.clone(), live, fullurl, &headers) {
        Ok(plan) => plan,
        // The library already emitted the error event; surface the failure
        // through the SDK's own error path with the catalog code intact.
        Err(err) => return Err(ProjectNameError::new(&err.code, &err.msg)),
    };

    // Copy-on-inject (station design 5.3): the generated request machinery
    // shares references (ctrl.explain.fetchdef IS this fetchdef), so the
    // real value only ever enters a deep clone.
    let senddef = if plan.headers.is_some() || plan.manual_redirect {
        let cloned = vs::clone(fetchdef);
        if let Some(injected) = &plan.headers {
            if !matches!(getp(&cloned, "headers"), Value::Map(_)) {
                setp(&cloned, "headers", Value::empty_map());
            }
            let hm = getp(&cloned, "headers");
            for (name, val) in injected.iter() {
                setp(&hm, name, Value::str(val.clone()));
            }
        }
        if plan.manual_redirect {
            // In-band annotation honoured by the default transport: with a
            // hosts policy, redirects come back manual (station design 8.2).
            setp(&cloned, "redirect", Value::str("manual"));
        }
        cloned
    } else {
        fetchdef.clone()
    };

    let started = station::now_ms();
    let out = inner(ctx, fullurl, &senddef);

    match &out {
        Err(err) => binding.done_err(corr, &method, fullurl, started, &err.code, &err.msg),
        Ok(res) => {
            let status = fres_status(res).unwrap_or(0);
            let bytes = fres_header(res, "content-length")
                .map(|len| fparse_int(&len, 0))
                .unwrap_or(0);
            binding.done_ok(corr, &method, fullurl, started, status, bytes);
        }
    }

    out
}

// The op identity from the SDK context - the one extraction the type
// boundary keeps out of the library ("_" is this SDK's unset marker).
fn op_identity(ctx: &Rc<Context>) -> (String, String) {
    let (mut entity, opname) = {
        let op = ctx.op.borrow();
        (
            if "_" == op.entity { String::new() } else { op.entity.clone() },
            if "_" == op.name { String::new() } else { op.name.clone() },
        )
    };
    if entity.is_empty() {
        if let Some(ent) = ctx.entity.borrow().clone() {
            entity = ent.get_name();
        }
    }
    (entity, opname)
}

fn outcome_of(ctx: &Rc<Context>) -> String {
    match ctx.result.borrow().clone() {
        None => "unknown".to_string(),
        Some(result) => {
            let result = result.borrow();
            if result.err.is_some() || !result.ok {
                "err".to_string()
            } else {
                "ok".to_string()
            }
        }
    }
}

// The SDK's Value tree as the station library's Json (functions dropped,
// absent-markers as null) - the embedded config and options cross the
// seam once, at init.
fn value_json(val: &Value) -> Json {
    match val {
        Value::Bool(flag) => Json::Bool(*flag),
        Value::Num(num) => Json::Num(*num),
        Value::Str(text) => Json::Str(text.clone()),
        Value::List(items) => Json::List(items.borrow().iter().map(value_json).collect()),
        Value::Map(entries) => {
            let mut out = BTreeMap::new();
            for (key, entry) in entries.borrow().iter() {
                if !matches!(entry, Value::Func(_)) {
                    out.insert(key.clone(), value_json(entry));
                }
            }
            Json::Map(out)
        }
        _ => Json::Null,
    }
}
