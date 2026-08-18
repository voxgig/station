//! The station side of the plugin contract (design §3), in ONE place:
//! bind() is what the generated station feature calls from its init(), so
//! every rule here - wrap position, registration, placeholder placement,
//! secret-name precedence, hosts policy, injection, event emission - is
//! the library's, never the adapter's.
//!
//! A port of typescript/src/adapter.ts featureBinding + the transport
//! middleware of Station.ts, which are canonical. Generated Rust SDKs
//! each vendor their own `Value` type and their `FetcherFn` is an SDK
//! type, so the physical wrap lives in the generated adapter and only
//! translated data crosses this seam:
//!
//!   - bind(BindSpec) once at init - the adapter converts the embedded
//!     config to Json, hands over the feature-name list for the §3.3
//!     guard, and applies the returned placeholder/base to its options;
//!   - prepare()/done_ok()/done_err() per request - the adapter extracts
//!     the header strings, deep-clones its fetchdef before applying an
//!     injected header set (copy-on-inject §5.3 - the clone is the
//!     adapter's ONLY job there; which headers change is decided here);
//!   - op_start()/op_done() from the hook bridge, keyed by the SDK's own
//!     per-op context id (design §3 item 3).
//!
//! There is no connect()/adopt() here: Rust SDK options are pure data
//! with no extend seam, so the inverted/ambient binding is the only form
//! (design §3.1, tier table) and retrofit is regeneration.

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use voxgig_sekreto::Json;

use crate::descriptor::normalize_descriptor;
use crate::error::StationError;
use crate::events::{HttpEvent, OpEvent, StationEvent};
use crate::jsonx::{jget, jstr, now_ms};
use crate::secrets::placeholder_for;
use crate::station::{PluginEntry, Station};

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
    /// The SDK's embedded config (ctx.config), converted to Json.
    pub config: Json,
    /// The client's feature list, by name, in init order - the §3.3
    /// position guard reads it (Rc<dyn Fn> cannot carry a wrap marker).
    pub feature_names: Vec<String>,
    /// The client's options.feature map (activation states, for the
    /// descriptor's features list).
    pub active_features: Json,
    /// The station feature's own options entry (options.feature.station):
    /// the config.options values - secret override etc.
    pub feature_opts: Json,
    /// The client's resolved options.base at init time.
    pub options_base: String,
    /// The embedded config's own options.base (the default the SDK ships).
    pub config_base: String,
    /// The client's options.apikey at init time ('' when unset).
    pub resident_apikey: String,
}

/// What bind() hands back for the adapter to apply - the one mutation
/// set the library cannot perform itself on the SDK's Value maps.
pub struct Bound {
    pub binding: Rc<Binding>,
    /// Plant into options.apikey (None when the plugin's model opted out
    /// of auth - such plugins skip credential planning, §5.3).
    pub placeholder: Option<String>,
    /// Apply to options.base (the profile's per-plugin base, design §3.5
    /// rung 4 - only handed back when the app left base at the SDK's
    /// config default, so an app-passed base always wins).
    pub base: Option<String>,
}

/// Per-request instructions for the adapter.
#[derive(Debug)]
pub struct TransportPlan {
    /// When Some, the full replacement header set (placeholder swapped
    /// for the real value). The adapter MUST deep-clone its fetchdef -
    /// headers map included - before applying it (copy-on-inject §5.3).
    pub headers: Option<BTreeMap<String, String>>,
    /// Annotate the cloned fetchdef with redirect: "manual" (§8.2's rule
    /// at the library seam: with a hosts policy, a 3xx must ride back
    /// like any other response, never pull a credentialed follow-up).
    pub manual_redirect: bool,
}

/// The bound station side the adapter forwards its hooks and transport
/// calls to.
pub struct Binding {
    pub slug: String,
    station: Rc<Station>,
    entry: Rc<PluginEntry>,
    placeholder: String,
    /// Per-op correlation state, keyed by the SDK's op context id:
    /// (corr, start ms). Set at PrePoint, consumed at PreDone /
    /// PreUnexpected; the transport reads it in between.
    corr: RefCell<HashMap<String, (String, i64)>>,
}

/// Resolve the station this activation binds to - the ambient instance
/// (Rust SDK options are pure data, so no handle can ride them; design
/// §3.1) - and make the §3 binding: registration, wrap position
/// verified, hooks bridged. No station open -> None: an activated
/// feature with no opened station is an inert no-op that emits nothing
/// and fails nothing. Misbinding - wrong wrap position, one client bound
/// twice - PANICS with the catalog code (construction-time
/// misconfiguration, the generated SDKs' own idiom).
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

    let (descriptor, warnings) = normalize_descriptor(&spec.config, &spec.active_features);
    let slug = jstr(&descriptor, "slug");

    // Secret name precedence (design §3.5/§9): the feature option
    // (in-code) beats the profile, which beats the descriptor default.
    // The override is recorded at registration; resolution reads it per
    // request (see transport()).
    let fopts_secret = jstr(&spec.feature_opts, "secret");

    let entry = station.register(spec.client.clone(), descriptor, warnings, &fopts_secret);

    // Base URL precedence (design §3.5): an app-passed base (7) beats the
    // profile (4), which beats the SDK's config default (1). With no
    // st.options() build step in Rust, "app-passed" is detected as
    // options.base differing from the config default - a base equal to
    // the default takes the profile's value, matching "did nothing
    // special" semantics. (A server-variable-templated default resolves
    // before init, so it never equals the raw config base and the profile
    // base is conservatively NOT applied there.)
    let mut base: Option<String> = None;
    if spec.options_base == spec.config_base {
        if let Some(plugin) = station.profile_plugin(&slug) {
            let profile_base = jstr(plugin, "base");
            if !profile_base.is_empty() {
                base = Some(profile_base);
            }
        }
    }

    let placeholder = placeholder_for(&slug);
    let auth_active = "R1" == entry.rung;

    // A real credential already resident in the options is hoisted into
    // the broker and replaced by the placeholder before construction
    // completes (design §3.1) - options_map() and prepare() output become
    // placeholder-safe from here on.
    if auth_active {
        let resident = &spec.resident_apikey;
        if !resident.is_empty() && resident != &placeholder {
            station.hoist(&slug, resident);
        }
    }

    let binding = Rc::new(Binding {
        slug,
        station,
        entry,
        placeholder: placeholder.clone(),
        corr: RefCell::new(HashMap::new()),
    });

    Some(Bound {
        binding,
        placeholder: if auth_active { Some(placeholder) } else { None },
        base,
    })
}

impl Binding {
    // --- hook bridge (design §3 item 3) ---

    /// PrePoint: open the per-op correlation. The http events the
    /// middleware emits for this op context carry the same corr as the op
    /// event PreDone/PreUnexpected will emit.
    pub fn op_start(&self, ctx_id: &str) {
        let corr = CORR_SEQ.with(|seq| {
            seq.set(seq.get() + 1);
            format!("c{}", seq.get())
        });
        self.corr
            .borrow_mut()
            .insert(ctx_id.to_string(), (corr, now_ms()));
    }

    /// The current op's correlation id, if PrePoint opened one.
    pub fn corr_of(&self, ctx_id: &str) -> Option<String> {
        self.corr.borrow().get(ctx_id).map(|(corr, _)| corr.clone())
    }

    /// PreDone / PreUnexpected: close the op with the outcome the adapter
    /// read from the SDK result ('ok' | 'err' | 'unknown' | 'unexpected').
    pub fn op_done(&self, ctx_id: &str, entity: &str, op: &str, outcome: &str) {
        let (corr, start) = match self.corr.borrow_mut().remove(ctx_id) {
            Some((corr, start)) => (Some(corr), Some(start)),
            None => (None, None),
        };
        self.station.emit(StationEvent {
            t: now_ms(),
            kind: "op".to_string(),
            plugin: Some(self.slug.clone()),
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

    // --- the transport middleware (design §3.3, §5.3) ---

    /// Pre-send decisions, in the canonical order: fail-closed `require`
    /// (§2.1: the operation path, never the constructor), the solo hosts
    /// policy (§16), then injection at the last boundary - never into
    /// mock transports (`live` false), so real credentials never enter
    /// in-memory mock stores. Errors are emitted as error events here and
    /// returned for the adapter to surface through the SDK's own error
    /// path.
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
            self.station.emit_err(&self.slug, corr, &err);
            return Err(err);
        }

        // Egress policy (design §16), solo half: the hosts allowlist is
        // enforced at the seam every request crosses.
        let hosts: Option<Vec<String>> = self
            .station
            .profile_plugin(&self.slug)
            .and_then(|plugin| jget(plugin, "policy"))
            .and_then(|policy| jget(policy, "hosts"))
            .and_then(|hosts| match hosts {
                Json::List(items) => Some(
                    items
                        .iter()
                        .filter_map(|item| match item {
                            Json::Str(text) => Some(text.clone()),
                            _ => None,
                        })
                        .collect(),
                ),
                _ => None,
            });

        let policed = hosts.is_some() && live;
        if let (Some(hosts), true) = (&hosts, live) {
            let host = hostname(fullurl);
            if !hosts.contains(&host) {
                let err = StationError::new(
                    "station_host_allow",
                    format!(
                        "egress to \"{}\" denied by the hosts policy of plugin \"{}\"",
                        host, self.slug
                    ),
                );
                self.station.emit_err(&self.slug, corr, &err);
                return Err(err);
            }
        }

        let mut injected: Option<BTreeMap<String, String>> = None;
        if live && "R1" == self.entry.rung {
            let secretname = self
                .station
                .secret_override_of(&self.slug)
                .filter(|name| !name.is_empty())
                .or_else(|| {
                    self.station
                        .profile_plugin(&self.slug)
                        .map(|plugin| jstr(plugin, "secret"))
                        .filter(|name| !name.is_empty())
                })
                .unwrap_or_else(|| {
                    jget(&self.entry.descriptor, "auth")
                        .map(|auth| jstr(auth, "secretname"))
                        .unwrap_or_default()
                });

            let value = match self.station.broker().value(&self.slug, &secretname) {
                Ok(value) => value,
                Err(err) => {
                    self.station.emit_err(&self.slug, corr, &err);
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

    /// The transport completed with a response: emit the http event -
    /// wire truth, one event per attempt (design §6).
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

    /// The transport failed: the attempt is still wire truth (status 0),
    /// and the failure enters the event stream scrubbed.
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
        self.station.emit_err(&self.slug, corr, &err);
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
            plugin: Some(self.slug.clone()),
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

/// The hostname (no port) of a URL, '' when unparseable - the hosts
/// policy's comparison key, mirroring the canonical port's
/// `new URL(u).hostname`.
pub fn hostname(url: &str) -> String {
    let (host, _path) = host_and_path(url);
    let bare = match host.find('[') {
        // [::1]:8080 - the bracketed form keeps its brackets off.
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

/// (host[:port], path) of a URL; ('', url) when unparseable - the http
/// event's fields, mirroring `new URL(u).host` / `.pathname`.
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
