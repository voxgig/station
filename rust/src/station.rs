//! The station library core, solo mode (design D1): fully functional
//! in-process with no other component running. The proxy (D2) is a
//! deferred amplifier - `require` therefore fails on the operation path
//! (design §2.1/§14), and `auto` degrades to solo with one warning event.
//!
//! A port of typescript/src/Station.ts, which is canonical, with the
//! transport middleware split across the binding seam (src/binding.rs):
//! generated Rust SDKs each carry their own vendored `Value` type, so the
//! generated adapter translates at the seam and every rule stays here.
//!
//! Single-threaded by design: the generated SDK world is Rc/RefCell
//! (neither Send nor Sync), so the ambient instance is thread-local and
//! nothing here synchronizes.

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;

use voxgig_sekreto::Json;

use crate::descriptor::canonical_serialize;
use crate::error::StationError;
use crate::events::{ErrEvent, EventBuffer, StationEvent, TapFn};
use crate::jsonx::{jget, jobj, jtext, now_ms};
use crate::profile::{load_config, resolve_profile, select_profile, ResolvedProfile};
use crate::secrets::SecretBroker;

/// Where the station's config comes from (the canonical port's
/// `opts.config`: undefined = discover, null = none, object = as given).
#[derive(Clone, Debug, Default, PartialEq)]
pub enum ConfigSource {
    /// Look station.json up from cwd (design §3.5). The default.
    #[default]
    Discover,
    /// No config at all (the canonical `config: null`).
    None,
    /// An explicit in-memory config.
    Value(Json),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct StationOptions {
    pub profile: Option<String>,
    /// 'auto' (default) | 'off' | 'require' | a proxy url (deferred).
    pub proxy: Option<String>,
    /// Where the station.json walk starts (default: cwd).
    pub folder: Option<std::path::PathBuf>,
    pub config: ConfigSource,
}

impl StationOptions {
    /// Options with config discovery disabled (`config: null`).
    pub fn no_config() -> StationOptions {
        StationOptions {
            config: ConfigSource::None,
            ..Default::default()
        }
    }

    /// The identity key for the open() conflict check.
    fn key(&self) -> String {
        let mut out = vec![
            ("profile", jtext(self.profile.clone().unwrap_or_default())),
            ("proxy", jtext(self.proxy.clone().unwrap_or_default())),
            (
                "folder",
                jtext(
                    self.folder
                        .as_ref()
                        .map(|p| p.display().to_string())
                        .unwrap_or_default(),
                ),
            ),
        ];
        match &self.config {
            ConfigSource::Discover => {}
            ConfigSource::None => out.push(("config", Json::Null)),
            ConfigSource::Value(val) => out.push(("config", val.clone())),
        }
        canonical_serialize(&jobj(out))
    }
}

pub struct PluginEntry {
    pub slug: String,
    pub descriptor: Json,
    /// 'none' | 'R1' (design §5.3).
    pub rung: String,
    /// The bound client, held so identity stays unique for the entry's
    /// lifetime (the adapter passes the SDK client as Rc<dyn Any>).
    pub client: Rc<dyn Any>,
    pub warnings: Vec<String>,
}

/// A plugins() row (design §3.2).
#[derive(Clone, Debug)]
pub struct PluginInfo {
    pub slug: String,
    pub descriptor: Json,
    pub rung: String,
    pub warnings: Vec<String>,
}

thread_local! {
    static AMBIENT: RefCell<Option<(Rc<Station>, String)>> = const { RefCell::new(None) };
}

pub struct Station {
    profile: ResolvedProfile,
    broker: SecretBroker,
    buffer: EventBuffer,
    registry: RefCell<BTreeMap<String, Rc<PluginEntry>>>,
    secret_override: RefCell<BTreeMap<String, String>>,
    require_proxy: bool,
    closed: Cell<bool>,
}

impl Station {
    /// Ambient instance (design §10.2): open() is the idempotent
    /// process-wide (per-thread - see the module note) singleton; a second
    /// open() with conflicting options PANICS with station_open_conflict;
    /// `Station::new` stays isolated for tests and multi-tenant hosts.
    /// open() is non-blocking - solo involves no network, and the
    /// deferred proxy probe must never change that.
    pub fn open(opts: StationOptions) -> Rc<Station> {
        let key = opts.key();
        AMBIENT.with(|ambient| {
            let mut slot = ambient.borrow_mut();
            if let Some((station, have)) = &*slot {
                if have != &key {
                    panic!(
                        "station_open_conflict: Station::open() was already \
                         called with different options"
                    );
                }
                return station.clone();
            }
            let station = Station::new(opts);
            *slot = Some((station.clone(), key));
            station
        })
    }

    /// The ambient instance, or None - never creates one. The generated
    /// station feature binds through this (design §3.1: binding is never
    /// implicit; only open() creates the ambient instance).
    pub fn current() -> Option<Rc<Station>> {
        AMBIENT.with(|ambient| ambient.borrow().as_ref().map(|(station, _)| station.clone()))
    }

    /// Test seam: drop the ambient instance.
    pub fn reset() {
        AMBIENT.with(|ambient| *ambient.borrow_mut() = None);
    }

    /// An isolated instance. Construction-time misconfiguration (a bad
    /// profile secret name, a chain sekreto refuses to build, an
    /// unparseable station.json) PANICS - the generated SDK constructors'
    /// own idiom - with the catalog code in the message.
    pub fn new(opts: StationOptions) -> Rc<Station> {
        let config: Option<Json> = match &opts.config {
            ConfigSource::Discover => load_config(opts.folder.as_deref()),
            ConfigSource::None => None,
            ConfigSource::Value(val) => Some(val.clone()),
        };

        let profile_name = select_profile(opts.profile.as_deref());
        let profile = match resolve_profile(config.as_ref(), &profile_name) {
            Ok(resolved) => resolved,
            Err(err) => panic!("{}", err),
        };
        let broker = match SecretBroker::new(&profile.providers) {
            Ok(broker) => broker,
            Err(err) => panic!("{}", err),
        };

        let proxy = opts.proxy.clone().unwrap_or_else(|| "auto".to_string());
        let station = Rc::new(Station {
            profile,
            broker,
            buffer: EventBuffer::new(None),
            registry: RefCell::new(BTreeMap::new()),
            secret_override: RefCell::new(BTreeMap::new()),
            require_proxy: "require" == proxy,
            closed: Cell::new(false),
        });

        if "auto" == proxy {
            // The probe is deferred with the proxy itself; absence degrades
            // to solo with a single warning event naming the cause (§14).
            station.emit(StationEvent {
                t: now_ms(),
                kind: "station".to_string(),
                meta: Some(jobj(vec![(
                    "warn",
                    jtext("proxy absent (not found); running solo"),
                )])),
                ..Default::default()
            });
        }

        station
    }

    // --- registration (design §3 item 1, called by the binding seam) ---

    /// The registry entry whose client IS this value, or None. Used by
    /// bind() for idempotency: a second arrival for the same client must
    /// no-op, while a genuinely second client of the same SDK class still
    /// fails register's slug check (§10.2).
    pub(crate) fn bound_entry(&self, client: &Rc<dyn Any>) -> Option<Rc<PluginEntry>> {
        let want = Rc::as_ptr(client) as *const ();
        for entry in self.registry.borrow().values() {
            if Rc::as_ptr(&entry.client) as *const () == want {
                return Some(entry.clone());
            }
        }
        None
    }

    pub(crate) fn register(
        &self,
        client: Rc<dyn Any>,
        descriptor: Json,
        warnings: Vec<String>,
        fopts_secret: &str,
    ) -> Rc<PluginEntry> {
        let slug = crate::jsonx::jstr(&descriptor, "slug");

        if self.registry.borrow().contains_key(&slug) {
            panic!(
                "station_bound_twice: plugin \"{}\" is already registered; \
                 binding one client twice is an error (§10.2)",
                slug
            );
        }

        if !fopts_secret.is_empty() {
            self.secret_override
                .borrow_mut()
                .insert(slug.clone(), fopts_secret.to_string());
        }

        let auth_active = matches!(
            jget(&descriptor, "auth").and_then(|a| jget(a, "active")),
            Some(Json::Bool(true))
        );
        let rung = if auth_active { "R1" } else { "none" };

        let name = crate::jsonx::jstr(&descriptor, "name");
        let version = crate::jsonx::jstr(&descriptor, "version");

        let entry = Rc::new(PluginEntry {
            slug: slug.clone(),
            descriptor,
            rung: rung.to_string(),
            client,
            warnings: warnings.clone(),
        });
        self.registry
            .borrow_mut()
            .insert(slug.clone(), entry.clone());

        for warn in &warnings {
            self.emit(StationEvent {
                t: now_ms(),
                kind: "station".to_string(),
                plugin: Some(slug.clone()),
                meta: Some(jobj(vec![("warn", jtext(warn.clone()))])),
                ..Default::default()
            });
        }
        self.emit(StationEvent {
            t: now_ms(),
            kind: "construct".to_string(),
            plugin: Some(slug.clone()),
            meta: Some(jobj(vec![
                ("name", jtext(name)),
                ("version", jtext(version)),
                ("rung", jtext(rung)),
            ])),
            ..Default::default()
        });

        entry
    }

    /// The profile's entry for one plugin, or None.
    pub(crate) fn profile_plugin(&self, slug: &str) -> Option<&Json> {
        self.profile.sdk.get(slug)
    }

    pub(crate) fn require_proxy(&self) -> bool {
        self.require_proxy
    }

    pub(crate) fn secret_override_of(&self, slug: &str) -> Option<String> {
        self.secret_override.borrow().get(slug).cloned()
    }

    pub(crate) fn broker(&self) -> &SecretBroker {
        &self.broker
    }

    pub(crate) fn hoist(&self, slug: &str, value: &str) {
        self.broker.hoist(slug, value);
        self.emit(StationEvent {
            t: now_ms(),
            kind: "station".to_string(),
            plugin: Some(slug.to_string()),
            meta: Some(jobj(vec![(
                "warn",
                jtext(
                    "a resident credential was hoisted into the broker and \
                     replaced by the placeholder; prefer configuring the secret \
                     name and letting sekreto resolve it",
                ),
            )])),
            ..Default::default()
        });
    }

    pub(crate) fn emit_err(&self, slug: &str, corr: Option<String>, err: &StationError) {
        self.emit(StationEvent {
            t: now_ms(),
            kind: "error".to_string(),
            plugin: Some(slug.to_string()),
            corr,
            err: Some(ErrEvent {
                code: Some(err.code.clone()),
                // The scrub keeps an upstream echo of a credential out of
                // the event stream (§7 as revised: exact-value, no floor).
                message: self.redact(&err.message()),
            }),
            ..Default::default()
        });
    }

    // --- the query/observe surface (design §3.2, §6) ---

    pub fn plugins(&self) -> Vec<PluginInfo> {
        self.registry
            .borrow()
            .values()
            .map(|entry| PluginInfo {
                slug: entry.slug.clone(),
                descriptor: entry.descriptor.clone(),
                rung: entry.rung.clone(),
                warnings: entry.warnings.clone(),
            })
            .collect()
    }

    pub fn descriptor_of(&self, slug: &str) -> Result<Json, StationError> {
        match self.registry.borrow().get(slug) {
            Some(entry) => Ok(entry.descriptor.clone()),
            None => Err(StationError::new(
                "station_no_plugin",
                format!(
                    "unknown plugin \"{}\"; known: [{}]",
                    slug,
                    self.registry
                        .borrow()
                        .keys()
                        .cloned()
                        .collect::<Vec<String>>()
                        .join(", ")
                ),
            )),
        }
    }

    pub fn canonical_descriptor(&self, slug: &str) -> Result<String, StationError> {
        Ok(canonical_serialize(&self.descriptor_of(slug)?))
    }

    pub fn events(&self) -> Vec<StationEvent> {
        self.buffer.events()
    }

    /// Live subscription; returns the tap id for untap().
    pub fn tap(&self, tap: TapFn) -> usize {
        self.buffer.tap(tap)
    }

    pub fn untap(&self, id: usize) {
        self.buffer.untap(id);
    }

    pub fn status(&self) -> Json {
        let (buffered, dropped) = self.buffer.status();
        let plugins: Vec<Json> = self
            .registry
            .borrow()
            .values()
            .map(|entry| {
                jobj(vec![
                    ("slug", jtext(entry.slug.clone())),
                    ("rung", jtext(entry.rung.clone())),
                ])
            })
            .collect();
        jobj(vec![
            ("mode", jtext("solo")),
            ("profile", jtext(self.profile.name.clone())),
            ("plugins", Json::List(plugins)),
            (
                "events",
                jobj(vec![
                    ("buffered", Json::Num(buffered as f64)),
                    ("dropped", Json::Num(dropped as f64)),
                ]),
            ),
        ])
    }

    pub fn redact(&self, text: &str) -> String {
        self.broker.scrub(text)
    }

    pub fn refresh_secrets(&self) {
        self.broker.refresh();
    }

    /// close(): flush (solo: nothing in flight), then warn on profile
    /// plugin keys that matched no registered plugin - a typo'd key
    /// silently configuring nothing is the worst outcome for a
    /// secrets-and-policy file (design §11).
    pub fn close(self: &Rc<Station>) {
        if self.closed.get() {
            return;
        }
        for slug in self.profile.sdk.keys() {
            if !self.registry.borrow().contains_key(slug) {
                self.emit(StationEvent {
                    t: now_ms(),
                    kind: "station".to_string(),
                    meta: Some(jobj(vec![(
                        "warn",
                        jtext(format!(
                            "profile plugin key \"{}\" matched no registered plugin",
                            slug
                        )),
                    )])),
                    ..Default::default()
                });
            }
        }
        self.closed.set(true);
        AMBIENT.with(|ambient| {
            let drop_it = matches!(
                &*ambient.borrow(),
                Some((station, _)) if Rc::ptr_eq(station, self)
            );
            if drop_it {
                *ambient.borrow_mut() = None;
            }
        });
    }

    pub(crate) fn emit(&self, ev: StationEvent) {
        self.buffer.emit(ev);
    }
}
