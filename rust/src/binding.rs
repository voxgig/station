
use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::error::StationError;
use crate::events::{HttpEvent, OpEvent, StationEvent};
use crate::jsonx::{jstr, now_ms};
use crate::secrets::placeholder_for;
use crate::station::{policy_allow, policy_hosts, PluginEntry, Station};

thread_local! {
    static CORR_SEQ: Cell<u64> = const { Cell::new(0) };
}

/// The generated adapter's view of one SDK client at feature init time.
/// Everything the binding needs crosses here once, so the library never
/// learns the generated crate's types.
pub struct BindSpec {
    /// The SDK client, as an opaque identity for the bound-twice and
    /// second-arrival checks. Held for the registry entry's lifetime.
    pub client: Rc<dyn Any>,
    pub config: Json,
    pub feature_names: Vec<String>,
    pub active_features: Json,
    /// The station feature's own options entry (options.feature.station):
    /// the config.options values - the secret override, and the INSTANCE
    /// NAME station knew before construction began (§6.1: `instance`, or
    /// `as` as a tag). Absent on a bare construction, which falls back to
    /// the descriptor slug - today's behaviour, unchanged to the byte.
    pub feature_opts: Json,
    pub options_base: String,
    pub config_base: String,
    pub resident_apikey: String,
}

/// What bind() hands back for the adapter to apply - the one mutation
/// set the library cannot perform itself on the SDK's Value maps.
pub struct Bound {
    pub binding: Rc<Binding>,
    /// Plant into options.apikey (None when the plugin's model opted out
    /// of auth - such plugins skip credential planning, §5.3).
    pub placeholder: Option<String>,
    /// Apply to options.base (the profile's per-instance base, design §3.5
    /// rung 4 - only handed back when the app left base at the SDK's
    /// config default, so an app-passed base always wins).
    pub base: Option<String>,
    pub allow: Option<Json>,
}

#[derive(Debug)]
pub struct TransportPlan {
    pub headers: Option<BTreeMap<String, String>>,
    pub manual_redirect: bool,
}

/// The bound station side the adapter forwards its hooks and transport
/// calls to.
pub struct Binding {
    /// The INSTANCE name (§6.1) - what everything keys on: the
    /// placeholder, the transport wrap, op events, error events. For an
    /// untagged instance it IS the api slug.
    pub name: String,
    pub api: String,
    station: Rc<Station>,
    entry: Rc<PluginEntry>,
    placeholder: String,
    /// Per-op correlation state, keyed by the SDK's op context id:
    /// (corr, start ms). Set at PrePoint, consumed at PreDone /
    /// PreUnexpected; the transport reads it in between.
    corr: RefCell<HashMap<String, (String, i64)>>,
}

pub fn bind(spec: BindSpec) -> Option<Bound> {
    let station = Station::current()?;

    // Same construction, second arrival: the first bind won, this one is
    // inert. See Station::bound_entry.
    if station.bound_entry(&spec.client).is_some() {
        return None;
    }

    // Position guard (design §3.3): the wrap must sit immediately outside
    // the base transport - inside retry/cache/ratelimit - or its http
    // events stop being wire truth. Position in the client's feature list
    // IS init order, so verify it and fail loudly.
    let names = &spec.feature_names;
    let self_at = names.iter().position(|n| "station" == n);
    let test_at = names.iter().position(|n| "test" == n);
    let expected = match test_at {
        Some(at) => at + 1,
        None => 0,
    };
    if self_at != Some(expected) {
        panic!(
            "station_wrap_order: station must init immediately after the base \
             transport; feature order is [{}]",
            names.join(", ")
        );
    }

    let (descriptor, warnings) = station.describe(&spec.config);
    let api = jstr(&descriptor, "slug");

    let entry = station.register(
        spec.client.clone(),
        descriptor,
        warnings,
        &spec.feature_opts,
    );
    let name = entry.name.clone();

    let block = station.block_for(&name);

    let mut base: Option<String> = None;
    if spec.options_base == spec.config_base {
        let profile_base = jstr(&block, "base");
        if !profile_base.is_empty() {
            base = Some(profile_base);
        }
    }

    // the SDK's own pipeline. Applied at binding time, which is inside the
    let allow = policy_allow(&block);

    let placeholder = placeholder_for(&name);
    let auth_active = "R1" == entry.rung;

    if auth_active {
        let resident = &spec.resident_apikey;
        if !resident.is_empty() && resident != &placeholder {
            station.hoist(&name, resident);
        }
    }

    let binding = Rc::new(Binding {
        name,
        api,
        station,
        entry,
        placeholder: placeholder.clone(),
        corr: RefCell::new(HashMap::new()),
    });

    Some(Bound {
        binding,
        placeholder: if auth_active { Some(placeholder) } else { None },
        base,
        allow,
    })
}

impl Binding {

    pub fn op_start(&self, ctx_id: &str) {
        let corr = CORR_SEQ.with(|seq| {
            seq.set(seq.get() + 1);
            format!("c{}", seq.get())
        });
        self.corr
            .borrow_mut()
            .insert(ctx_id.to_string(), (corr, now_ms()));
    }

    pub fn corr_of(&self, ctx_id: &str) -> Option<String> {
        self.corr.borrow().get(ctx_id).map(|(corr, _)| corr.clone())
    }

    pub fn op_done(&self, ctx_id: &str, entity: &str, op: &str, outcome: &str) {
        let (corr, start) = match self.corr.borrow_mut().remove(ctx_id) {
            Some((corr, start)) => (Some(corr), Some(start)),
            None => (None, None),
        };
        self.station.emit(StationEvent {
            t: now_ms(),
            kind: "op".to_string(),
            plugin: Some(self.name.clone()),
            api: Some(self.api.clone()),
            corr,
            op: Some(OpEvent {
                entity: entity.to_string(),
                op: op.to_string(),
                outcome: outcome.to_string(),
                duration_ms: start.map(|s| now_ms() - s).unwrap_or(0),
            }),
            ..Default::default()
        });
    }


    pub fn prepare(
        &self,
        corr: Option<String>,
        live: bool,
        fullurl: &str,
        headers: &BTreeMap<String, String>,
    ) -> Result<TransportPlan, StationError> {
        if self.station.require_proxy() {
            let err = StationError::new(
                "station_no_proxy",
                "proxy: \"require\" is set and no proxy is attached",
            );
            self.station.emit_err(&self.name, corr, &err);
            return Err(err);
        }

        let hosts: Option<Vec<String>> = policy_hosts(&self.station.block_for(&self.name));

        let policed = hosts.is_some() && live;
        if let (Some(hosts), true) = (&hosts, live) {
            let host = hostname(fullurl);
            if !hosts.contains(&host) {
                let err = StationError::new(
                    "station_host_allow",
                    format!(
                        "egress to \"{}\" denied by the hosts policy of plugin \"{}\"",
                        host, self.name
                    ),
                );
                self.station.emit_err(&self.name, corr, &err);
                return Err(err);
            }
        }

        let mut injected: Option<BTreeMap<String, String>> = None;
        if live && "R1" == self.entry.rung {
            let secretname = self.entry.secretname.clone();

            let value = match self.station.broker().value(&self.name, &secretname) {
                Ok(value) => value,
                Err(err) => {
                    self.station.emit_err(&self.name, corr, &err);
                    return Err(err);
                }
            };

            let mut out = headers.clone();
            for (_name, entry) in out.iter_mut() {
                if entry.contains(&self.placeholder) {
                    *entry = entry.replace(&self.placeholder, &value);
                }
            }
            injected = Some(out);
        }

        Ok(TransportPlan {
            headers: injected,
            manual_redirect: policed,
        })
    }

    pub fn done_ok(
        &self,
        corr: Option<String>,
        method: &str,
        fullurl: &str,
        started: i64,
        status: i64,
        bytes: i64,
    ) {
        self.emit_http(corr, method, fullurl, started, status, bytes);
    }

    pub fn done_err(
        &self,
        corr: Option<String>,
        method: &str,
        fullurl: &str,
        started: i64,
        code: &str,
        msg: &str,
    ) {
        self.emit_http(corr.clone(), method, fullurl, started, 0, 0);
        let err = StationError::new(code, msg);
        self.station.emit_err(&self.name, corr, &err);
    }

    fn emit_http(
        &self,
        corr: Option<String>,
        method: &str,
        fullurl: &str,
        started: i64,
        status: i64,
        bytes: i64,
    ) {
        let (host, path) = host_and_path(fullurl);
        self.station.emit(StationEvent {
            t: started,
            kind: "http".to_string(),
            plugin: Some(self.name.clone()),
            api: Some(self.api.clone()),
            corr,
            http: Some(HttpEvent {
                method: if method.is_empty() {
                    "GET".to_string()
                } else {
                    method.to_string()
                },
                host,
                path,
                status,
                duration_ms: now_ms() - started,
                bytes,
            }),
            ..Default::default()
        });
    }
}

pub fn hostname(url: &str) -> String {
    let (host, _path) = host_and_path(url);
    let bare = match host.find('[') {
        Some(_) => host
            .trim_start_matches('[')
            .split(']')
            .next()
            .unwrap_or("")
            .to_string(),
        None => host.split(':').next().unwrap_or("").to_string(),
    };
    bare
}

fn host_and_path(url: &str) -> (String, String) {
    let rest = match url.find("://") {
        Some(at) => &url[at + 3..],
        None => return (String::new(), url.to_string()),
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let host = rest[..end].to_string();
    let tail = &rest[end..];
    let path = match tail.chars().next() {
        Some('/') => tail.split(['?', '#']).next().unwrap_or("/").to_string(),
        _ => "/".to_string(),
    };
    (host, path)
}
