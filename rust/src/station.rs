
use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::descriptor::{canonical_serialize, normalize_descriptor, secretname_default};
use crate::error::{is_known_code, StationError};
use crate::events::{ErrEvent, EventBuffer, StationEvent, TapFn};
use crate::factory::{factory_for, provide, Factory, FactoryEntry};
use crate::feature::{
    check_features, check_pin, compose_features, fault_messages, feature_names, feature_sources,
    merge_features, resolve_order,
};
use crate::instance::instance_ref;
use crate::jsonx::{jget, jobj, jstr, jtext, jtextof, now_ms};
use crate::profile::{
    config_scope, load_config, refapi, resolve_profile, select_profile, ResolvedProfile,
};
use crate::secrets::SecretBroker;
use crate::shape::{normalize_config, validate_config};

/// Where the station's config comes from (the canonical port's
/// `opts.config`: undefined = discover, null = none, object = as given).
#[derive(Clone, Default)]
pub enum ConfigSource {
    #[default]
    Discover,
    None,
    Value(Json),
}

impl PartialEq for ConfigSource {
    fn eq(&self, other: &ConfigSource) -> bool {
        match (self, other) {
            (ConfigSource::Discover, ConfigSource::Discover) => true,
            (ConfigSource::None, ConfigSource::None) => true,
            (ConfigSource::Value(one), ConfigSource::Value(two)) => one.same(two),
            _ => false,
        }
    }
}

impl std::fmt::Debug for ConfigSource {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigSource::Discover => out.write_str("Discover"),
            ConfigSource::None => out.write_str("None"),
            ConfigSource::Value(val) => write!(out, "Value({})", val.json()),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct StationOptions {
    pub profile: Option<String>,
    pub proxy: Option<String>,
    pub folder: Option<std::path::PathBuf>,
    pub config: ConfigSource,
    pub repo_scoped: Option<bool>,
    /// Accepted and INERT in this port (§5.4 item 4): there is no
    /// loader, so `Some(false)` changes nothing and neither does
    /// `Some(true)`.
    pub load: Option<bool>,
}

impl StationOptions {
    pub fn no_config() -> StationOptions {
        StationOptions {
            config: ConfigSource::None,
            ..Default::default()
        }
    }

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
        if let Some(scoped) = self.repo_scoped {
            out.push(("repoScoped", Json::Bool(scoped)));
        }
        if let Some(load) = self.load {
            out.push(("load", Json::Bool(load)));
        }
        match &self.config {
            ConfigSource::Discover => {}
            ConfigSource::None => out.push(("config", Json::Null)),
            ConfigSource::Value(val) => out.push(("config", val.clone())),
        }
        canonical_serialize(&jobj(out))
    }
}

/// One live instance (design §6.1): the registry is keyed by `name`, and
/// `api` is what groups its siblings.
pub struct PluginEntry {
    pub name: String,
    pub api: String,
    pub slug: String,
    pub descriptor: Json,
    pub rung: String,
    /// The EFFECTIVE secret name, resolved once at registration and read
    /// from here at the transport seam with NO FALLBACK: re-deriving it
    /// there is how a tagged instance with no explicit `secret` reads
    /// `stripe.apikey` where registration recorded `stripe_test.apikey`.
    pub secretname: String,
    /// The bound client, held so identity stays unique for the entry's
    /// lifetime (the adapter passes the SDK client as Rc<dyn Any>).
    pub client: Rc<dyn Any>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct PluginInfo {
    pub name: String,
    pub api: String,
    pub slug: String,
    pub descriptor: Json,
    pub rung: String,
    pub secretname: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Instance {
    pub name: String,
    pub api: String,
    /// `active: false` means BARRED FROM RUNNING - a declaration that
    /// stays in the file and here while being refused a client.
    pub active: bool,
    pub live: bool,
    pub rung: String,
    pub block: Json,
}

#[derive(Clone, Debug)]
pub struct FeatureSet {
    pub ordered: Vec<String>,
    pub merged: Json,
    pub from: BTreeMap<String, BTreeMap<String, String>>,
    /// The declaration order the merge saw (see feature.rs: this port
    /// has no ordered map, so it is bytewise key order).
    pub declared: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct FeatureRow {
    pub instance: String,
    pub api: String,
    pub ordered: Vec<String>,
    pub merged: Json,
    pub from: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Clone, Debug, Default)]
pub struct FeatureFilter {
    pub instance: Option<String>,
    pub api: Option<String>,
    pub feature: Option<String>,
    /// Set by `loose_filter`: match the text against EITHER the instance
    /// name or the api.
    pub loose: bool,
}

pub fn loose_filter(text: &str) -> FeatureFilter {
    FeatureFilter {
        instance: Some(text.to_string()),
        api: Some(text.to_string()),
        loose: true,
        ..Default::default()
    }
}

#[derive(Clone, Debug)]
pub struct CheckFailure {
    pub name: String,
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Default)]
pub struct CheckResult {
    pub ok: Vec<String>,
    pub failed: Vec<CheckFailure>,
}

#[derive(Clone, Debug, Default)]
pub struct WarmResult {
    pub warmed: Vec<String>,
    pub missed: Vec<String>,
}

thread_local! {
    static AMBIENT: RefCell<Option<(Rc<Station>, String)>> = const { RefCell::new(None) };
}

pub struct Station {
    opts: StationOptions,
    profile: ResolvedProfile,
    /// The RAW config, kept for provenance: the resolved profile has
    /// already collapsed the levels provenance has to name.
    raw: Option<Json>,
    repo_scoped: bool,
    broker: SecretBroker,
    buffer: EventBuffer,
    registry: RefCell<BTreeMap<String, Rc<PluginEntry>>>,
    clients: RefCell<BTreeMap<String, Rc<dyn Any>>>,
    alias_of: RefCell<BTreeMap<String, String>>,
    descriptor_cache: RefCell<BTreeMap<String, (Json, Vec<String>)>>,
    require_proxy: bool,
    closed: Cell<bool>,
}

impl Station {
    /// §6.2's second path, and the ONLY bootstrap this port offers (see
    /// loader.rs): register an api's factory in the one process-global
    /// (per-thread) table. There is one registry, not two.
    pub fn provide(api: &str, factory: Factory) -> Result<Rc<FactoryEntry>, StationError> {
        provide(api, factory)
    }

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
    pub fn current() -> Option<Rc<Station>> {
        AMBIENT.with(|ambient| ambient.borrow().as_ref().map(|(station, _)| station.clone()))
    }

    pub fn reset() {
        AMBIENT.with(|ambient| *ambient.borrow_mut() = None);
    }

    /// malformed station.json, a bad profile secret name, a chain sekreto
    pub fn new(opts: StationOptions) -> Rc<Station> {
        let incode = matches!(opts.config, ConfigSource::Value(_));
        let noconfig = matches!(opts.config, ConfigSource::None);
        let config: Option<Json> = match &opts.config {
            ConfigSource::Discover => match load_config(opts.folder.as_deref()) {
                Ok(found) => found,
                Err(err) => panic!("{}", err),
            },
            ConfigSource::None => None,
            ConfigSource::Value(val) => Some(val.clone()),
        };

        // wrote it, so it is repo-scoped by construction), then where the
        // precedence bug this order exists to avoid.
        let repo_scoped = match opts.repo_scoped {
            Some(explicit) => explicit,
            None if incode || noconfig => true,
            None => "user" != config_scope(opts.folder.as_deref()),
        };

        if let Some(config) = &config {
            if let Err(err) = validate_config(&normalize_config(config)) {
                panic!("{}", err);
            }
        }

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
            opts,
            profile,
            raw: config,
            repo_scoped,
            broker,
            buffer: EventBuffer::new(None),
            registry: RefCell::new(BTreeMap::new()),
            clients: RefCell::new(BTreeMap::new()),
            alias_of: RefCell::new(BTreeMap::new()),
            descriptor_cache: RefCell::new(BTreeMap::new()),
            require_proxy: "require" == proxy,
            closed: Cell::new(false),
        });

        if "auto" == proxy {
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

        station.warn_packages();

        station
    }

    pub fn repo_scoped(&self) -> bool {
        self.repo_scoped
    }

    /// The RAW config this station was opened with, kept for provenance.
    pub fn raw(&self) -> Option<&Json> {
        self.raw.as_ref()
    }


    /// The plain options map a generated constructor already accepts: the
    pub fn options(&self, extra: &Json) -> Json {
        self.options_for("", extra)
    }

    /// `options` with the INSTANCE NAME the construction registers under
    /// (§6.1). Rust cannot overload on a leading optional argument the
    /// way the canonical `options(instanceName?, extra?)` does, so the
    /// name gets its own method and every existing `options(&extra)` call
    pub fn options_for(&self, instance: &str, extra: &Json) -> Json {
        let mut out: BTreeMap<String, Json> = match extra {
            Json::Map(entries) => entries.clone(),
            _ => BTreeMap::new(),
        };

        let mut features: BTreeMap<String, Json> = match out.get("feature") {
            Some(Json::Map(entries)) => entries.clone(),
            _ => BTreeMap::new(),
        };
        let mut sopts: BTreeMap<String, Json> = match features.get("station") {
            Some(Json::Map(entries)) => entries.clone(),
            _ => BTreeMap::new(),
        };
        sopts.insert("active".to_string(), Json::Bool(true));
        if !instance.is_empty() {
            sopts.insert("instance".to_string(), jtext(instance));
        }
        features.insert("station".to_string(), Json::Map(sopts));
        out.insert("feature".to_string(), Json::Map(features));

        Json::Map(out)
    }

    // --- registration (design §3 item 1, called by the binding seam) ---

    /// The registry entry whose client IS this value, or None. Used by
    /// bind() for idempotency: a second arrival for the same client must
    /// no-op, while a genuinely second client of the same INSTANCE still
    pub(crate) fn bound_entry(&self, client: &Rc<dyn Any>) -> Option<Rc<PluginEntry>> {
        let want = Rc::as_ptr(client) as *const ();
        for entry in self.registry.borrow().values() {
            if Rc::as_ptr(&entry.client) as *const () == want {
                return Some(entry.clone());
            }
        }
        None
    }

    /// profile declares it, otherwise its API'S.
    /// alone (an api block declares no instance, §3.1), which leaves an
    /// IMPERATIVE instance - named but never written into config - with
    /// ONE RULE, ONE PLACE: registration and the transport seam both ask
    /// here, because them disagreeing is how the credential and the
    pub fn block_for(&self, name: &str) -> Json {
        let declared = self.declared_ref(name);
        if let Some(block) = self.profile.sdk.get(&declared) {
            return block.clone();
        }
        self.profile
            .api
            .get(&refapi(name))
            .cloned()
            .unwrap_or_else(|| Json::Map(BTreeMap::new()))
    }

    /// itself. `create("stripe$prod")` registers under `stripe$1`, and
    /// every question about that client's configuration - its secret, its
    pub fn declared_ref(&self, name: &str) -> String {
        self.alias_of
            .borrow()
            .get(name)
            .cloned()
            .unwrap_or_else(|| name.to_string())
    }

    /// Register one construction. `fopts` is the station feature's own
    pub(crate) fn register(
        &self,
        client: Rc<dyn Any>,
        descriptor: Json,
        warnings: Vec<String>,
        fopts: &Json,
    ) -> Rc<PluginEntry> {
        let api = jstr(&descriptor, "slug");

        let name = match instance_ref(&api, fopts) {
            Ok(name) => name,
            Err(err) => panic!("{}", err),
        };

        let block = self.block_for(&name);

        // by every instance of an api and cannot hold two
        let mut secretname = jstr(fopts, "secret");
        if secretname.is_empty() {
            secretname = jstr(&block, "secret");
        }
        if secretname.is_empty() {
            secretname = secretname_default(&self.declared_ref(&name));
        }

        if self.registry.borrow().contains_key(&name) {
            panic!(
                "station_bound_twice: instance \"{}\" is already registered; \
                 binding one client twice is an error (§10.2)",
                name
            );
        }

        let auth_active = matches!(
            jget(&descriptor, "auth").and_then(|a| jget(a, "active")),
            Some(Json::Bool(true))
        );
        let rung = if auth_active { "R1" } else { "none" };
        if !auth_active {
            secretname = String::new();
        }

        let sdkname = jstr(&descriptor, "name");
        let version = jstr(&descriptor, "version");

        let entry = Rc::new(PluginEntry {
            name: name.clone(),
            api: api.clone(),
            slug: api.clone(),
            descriptor,
            rung: rung.to_string(),
            secretname,
            client,
            warnings: warnings.clone(),
        });
        self.registry
            .borrow_mut()
            .insert(name.clone(), entry.clone());

        for warn in &warnings {
            self.emit(StationEvent {
                t: now_ms(),
                kind: "station".to_string(),
                plugin: Some(name.clone()),
                api: Some(api.clone()),
                meta: Some(jobj(vec![("warn", jtext(warn.clone()))])),
                ..Default::default()
            });
        }
        self.emit(StationEvent {
            t: now_ms(),
            kind: "construct".to_string(),
            plugin: Some(name),
            api: Some(api),
            meta: Some(jobj(vec![
                ("name", jtext(sdkname)),
                ("version", jtext(version)),
                ("rung", jtext(rung)),
            ])),
            ..Default::default()
        });

        entry
    }

    pub(crate) fn describe(&self, config: &Json) -> (Json, Vec<String>) {
        let slug = jget(config, "main")
            .map(|main| jstr(main, "slug"))
            .unwrap_or_default();

        if !slug.is_empty() {
            if let Some(hit) = self.descriptor_cache.borrow().get(&slug) {
                return hit.clone();
            }
        }

        let (descriptor, warnings) = normalize_descriptor(config, &Json::Null);
        self.descriptor_cache.borrow_mut().insert(
            jstr(&descriptor, "slug"),
            (descriptor.clone(), warnings.clone()),
        );
        (descriptor, warnings)
    }

    pub(crate) fn require_proxy(&self) -> bool {
        self.require_proxy
    }

    pub(crate) fn broker(&self) -> &SecretBroker {
        &self.broker
    }

    pub(crate) fn hoist(&self, name: &str, value: &str) {
        self.broker.hoist(name, value);
        self.emit(StationEvent {
            t: now_ms(),
            kind: "station".to_string(),
            plugin: Some(name.to_string()),
            api: Some(refapi(name)),
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

    pub(crate) fn emit_err(&self, name: &str, corr: Option<String>, err: &StationError) {
        self.emit(StationEvent {
            t: now_ms(),
            kind: "error".to_string(),
            plugin: Some(name.to_string()),
            api: Some(refapi(name)),
            corr,
            err: Some(ErrEvent {
                code: Some(err.code.clone()),
                message: self.redact(&err.message()),
            }),
            ..Default::default()
        });
    }


    /// The client for a declared instance, CONSTRUCTED ON FIRST ASK AND
    /// CACHED by name. Synchronous, which is what makes "get it where you
    /// The client is `Rc<dyn Any>`: a station library cannot name a
    pub fn sdk(&self, name: &str) -> Result<Rc<dyn Any>, StationError> {
        if let Some(cached) = self.clients.borrow().get(name) {
            return Ok(cached.clone());
        }
        let client = self.build(name, None, None)?;
        self.clients
            .borrow_mut()
            .insert(name.to_string(), client.clone());
        Ok(client)
    }

    pub fn create(
        &self,
        name: &str,
        overrides: Option<&Json>,
    ) -> Result<Rc<dyn Any>, StationError> {
        let tag = self.autotag(name);
        self.build(name, Some(&tag), overrides)
    }

    ///
    /// THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
    /// `create("stripe$prod")` would take that identity, `instances()`
    /// Declaration reserves the name whether or not it has been built.
    pub fn autotag(&self, name: &str) -> String {
        let api = refapi(name);
        let mut at = 1u64;
        loop {
            let reference = format!("{}${}", api, at);
            let live = self.registry.borrow().contains_key(&reference);
            let declared = self.profile.sdk.contains_key(&reference);
            if !live && !declared {
                return reference;
            }
            at += 1;
        }
    }

    /// The shared construction path behind `sdk()` and `create()`. `as`
    /// is the ASSIGNED tag, or None when the instance is built under its
    /// own name.
    pub fn build(
        &self,
        name: &str,
        as_tag: Option<&str>,
        overrides: Option<&Json>,
    ) -> Result<Rc<dyn Any>, StationError> {
        if self.closed.get() {
            return Err(StationError::new("station_no_plugin", "station is closed"));
        }

        let block = match self.profile.sdk.get(name) {
            Some(block) => block.clone(),
            None => {
                let declared: Vec<String> = self.profile.sdk.keys().cloned().collect();
                return Err(StationError::new(
                    "station_no_instance",
                    format!(
                        "no declared instance \"{}\"; declared: [{}]",
                        name,
                        declared.join(", ")
                    ),
                ));
            }
        };

        if matches!(jget(&block, "active"), Some(Json::Bool(false))) {
            return Err(StationError::new(
                "station_instance_inactive",
                format!(
                    "instance \"{}\" is declared with `active: false`, which \
                     bars it from running while keeping it visible in instances()",
                    name
                ),
            ));
        }

        let api = refapi(name);
        let entry = self.resolve_factory(&api, &block)?;
        let resolved = self.features_of(name)?;

        // first moment validation is possible - and running it in check()
        // alone left production sdk() silently ignoring an unknown option
        // like `retry.retires`. One call here closes it, because EVERY
        let faults = check_features(&resolved.merged, &entry.descriptor);
        if !faults.is_empty() {
            return Err(StationError::new(
                &faults[0].code,
                fault_messages(&faults),
            ));
        }

        // here and re-added by options_for: a config file that can switch
        // off the component reading it is not a surface, it is a trap.
        // THE MAP CANNOT CARRY THE ORDER - a generated Rust constructor
        // invariant - the pin - bind() still verifies and fails loudly
        let rows = resolve_order(&resolved.merged, &resolved.declared)?;
        let kept: Vec<crate::feature::Ordered> = rows
            .into_iter()
            .filter(|row| "station" != row.name)
            .collect();
        let mut features: BTreeMap<String, Json> = BTreeMap::new();
        for one in compose_features(&kept) {
            let fname = jstr(&one, "name");
            let rest: BTreeMap<String, Json> = match &one {
                Json::Map(entries) => entries
                    .iter()
                    .filter(|(key, _)| "name" != key.as_str())
                    .map(|(key, val)| (key.clone(), val.clone()))
                    .collect(),
                _ => BTreeMap::new(),
            };
            features.insert(fname, Json::Map(rest));
        }

        let mut options: BTreeMap<String, Json> = match jget(&block, "options") {
            Some(Json::Map(entries)) => entries.clone(),
            _ => BTreeMap::new(),
        };
        let base = jstr(&block, "base");
        if !base.is_empty() {
            options.insert("base".to_string(), jtext(base));
        }
        if let Some(Json::Map(extra)) = overrides {
            for (key, val) in extra.iter() {
                options.insert(key.clone(), val.clone());
            }
            if let Some(Json::Map(over)) = extra.get("feature") {
                for (key, val) in over.iter() {
                    features.insert(key.clone(), val.clone());
                }
            }
        }
        options.insert("feature".to_string(), Json::Map(features));

        let mut register_as = name.to_string();
        if let Some(tag) = as_tag {
            if !tag.is_empty() && tag != name {
                self.alias_of
                    .borrow_mut()
                    .insert(tag.to_string(), name.to_string());
                register_as = tag.to_string();
            }
        }

        // THERE IS NO CARRIED ADAPTER IN THIS PORT - Rust SDK options are
        // pure data with no extend seam (§3.1, tier table) - so the
        // retrofit path is regeneration with the station feature
        Ok((entry.construct)(
            &self.options_for(&register_as, &Json::Map(options)),
        ))
    }

    /// self-registration and the loader both fall away and `provide` is
    /// the whole bootstrap. The message names only the remedy this port
    /// actually offers - telling a Rust user to set `api.<slug>.package`
    pub fn resolve_factory(
        &self,
        api: &str,
        _block: &Json,
    ) -> Result<Rc<FactoryEntry>, StationError> {
        if let Some(direct) = factory_for(api) {
            return Ok(direct);
        }
        Err(StationError::new(
            "station_no_factory",
            format!(
                "no factory for api \"{}\"; call Station::provide(\"{}\", ...) \
                 with the generated crate's constructor and config. `package` \
                 is not honoured in the Rust port: a Rust dependency is linked, \
                 so there is no import-by-name at run time, and Rust has no \
                 module-init hook for a crate to self-register from (§6.3)",
                api, api
            ),
        ))
    }

    /// Always None here, and it says why once per api at open (§5.4 item
    /// 2). `package` and `export` stay IN THE GRAMMAR - they are shape
    /// keys, the corpus validates configs carrying them, and removing
    /// them would break one-config-file-serves-a-polyglot-fleet - but
    /// this port cannot honour them, and silence about that is worse than
    pub fn loader_package(&self, _api: &str, _block: &Json) -> Option<String> {
        None
    }

    /// Present and INERT (§5.4 item 4): the preload exists so one startup
    /// sequence serves a polyglot fleet. `StationOptions { load: Some(false) }`
    pub fn load(&self) -> Result<(), StationError> {
        let _ = self.opts.load;
        Ok(())
    }

    /// One warning event per api whose declared block carries a non-empty
    fn warn_packages(&self) {
        let mut blocks: BTreeMap<String, Json> = BTreeMap::new();
        for (reference, block) in self.profile.sdk.iter() {
            blocks.insert(reference.clone(), block.clone());
        }
        for (slug, block) in self.profile.api.iter() {
            blocks.entry(slug.clone()).or_insert_with(|| block.clone());
        }

        let mut seen: BTreeSet<String> = BTreeSet::new();
        for (reference, block) in blocks.iter() {
            if jstr(block, "package").is_empty() {
                continue;
            }
            let api = refapi(reference);
            if !seen.insert(api.clone()) {
                continue;
            }
            self.emit(StationEvent {
                t: now_ms(),
                kind: "station".to_string(),
                plugin: Some(api.clone()),
                api: Some(api.clone()),
                meta: Some(jobj(vec![(
                    "warn",
                    jtext(format!(
                        "`package` is not honoured in the Rust port: a Rust \
                         dependency is linked, so there is no import-by-name at \
                         run time. api \"{}\" must arrive by \
                         Station::provide (§6.3); everything else in this \
                         config still applies",
                        api
                    )),
                )])),
                ..Default::default()
            });
        }
    }

    /// The merged, ordered feature set for one instance, WITH PROVENANCE
    /// Provenance is the half that makes a fleet view usable rather than
    /// question, and a merged map alone cannot answer it.
    pub fn features_of(&self, name: &str) -> Result<FeatureSet, StationError> {
        let api = refapi(name);
        let empty = Json::Map(BTreeMap::new());

        let profiles = self
            .raw
            .as_ref()
            .and_then(|raw| jget(raw, "profiles"))
            .unwrap_or(&empty);
        let base = jget(profiles, "default").unwrap_or(&empty);
        let overlay = if "default" == self.profile.name {
            &empty
        } else {
            jget(profiles, &self.profile.name).unwrap_or(&empty)
        };

        let levels = [
            "default.feature".to_string(),
            "default.api".to_string(),
            "default.sdk".to_string(),
            format!("{}.feature", self.profile.name),
            format!("{}.api", self.profile.name),
            format!("{}.sdk", self.profile.name),
        ];
        let sources = feature_sources(Some(base), Some(overlay), &api, name);

        let mut from: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
        for (at, src) in sources.iter().enumerate() {
            let entries = match src {
                Some(Json::Map(entries)) => entries,
                _ => continue,
            };
            for (fname, entry) in entries.iter() {
                let fields = match entry {
                    Json::Map(fields) => fields,
                    _ => continue,
                };
                let slot = from.entry(fname.clone()).or_default();
                for key in fields.keys() {
                    slot.insert(key.clone(), levels[at].clone());
                }
            }
        }

        let merged = merge_features(&sources);
        let mut mergedmap: BTreeMap<String, Json> = match merged {
            Json::Map(entries) => entries,
            _ => BTreeMap::new(),
        };
        let mut declared: Vec<String> = mergedmap.keys().cloned().collect();

        // SDK `ratelimit` feature, configured by station". Composed HERE,
        // SDK with no ratelimit feature is station_feature_unknown, not a
        let block = self.block_for(name);
        if let Some(Json::Map(budget)) = jget(&block, "policy").and_then(|p| jget(p, "budget")) {
            let mut entry: BTreeMap<String, Json> = match mergedmap.get("ratelimit") {
                Some(Json::Map(prior)) => prior.clone(),
                _ => BTreeMap::new(),
            };
            entry.insert("active".to_string(), Json::Bool(true));
            let slot = from.entry("ratelimit".to_string()).or_default();
            slot.insert("active".to_string(), "policy.budget".to_string());
            if let Some(rps) = budget.get("rps") {
                if !matches!(rps, Json::Null) {
                    entry.insert("rate".to_string(), rps.clone());
                    slot.insert("rate".to_string(), "policy.budget".to_string());
                }
            }
            if let Some(concurrency) = budget.get("concurrency") {
                if !matches!(concurrency, Json::Null) {
                    entry.insert("burst".to_string(), concurrency.clone());
                    slot.insert("burst".to_string(), "policy.budget".to_string());
                }
            }
            if !mergedmap.contains_key("ratelimit") {
                declared.push("ratelimit".to_string());
            }
            mergedmap.insert("ratelimit".to_string(), Json::Map(entry));
        }

        // THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station`
        // is never in `merged` - feature.station is reserved and rejected
        // at validation (§8.4) - so without it check_pin finds no station
        // rather than rejected, and the reported order would omit the one
        // feature whose position is supposedly pinned.
        let mut withstation = mergedmap.clone();
        withstation.insert(
            "station".to_string(),
            jobj(vec![("active", Json::Bool(true))]),
        );
        let mut orderdeclared = declared.clone();
        orderdeclared.push("station".to_string());

        let ordered = resolve_order(&Json::Map(withstation), &orderdeclared)?;
        check_pin(&ordered)?;

        Ok(FeatureSet {
            ordered: feature_names(&ordered),
            merged: Json::Map(mergedmap),
            from,
            declared,
        })
    }

    /// The fleet feature view: instance x feature, effective options, and
    pub fn features(&self, filter: Option<&FeatureFilter>) -> Result<Vec<FeatureRow>, StationError> {
        let none = FeatureFilter::default();
        let want = filter.unwrap_or(&none);

        let mut rows: Vec<FeatureRow> = Vec::new();
        for one in self.instances() {
            if want.loose {
                if let Some(text) = &want.instance {
                    if &one.name != text && &one.api != text {
                        continue;
                    }
                }
            } else {
                if let Some(text) = &want.instance {
                    if &one.name != text && &one.api != text {
                        continue;
                    }
                }
                if let Some(text) = &want.api {
                    if &one.api != text {
                        continue;
                    }
                }
            }

            let resolved = self.features_of(&one.name)?;
            rows.push(FeatureRow {
                instance: one.name.clone(),
                api: one.api.clone(),
                ordered: resolved.ordered,
                merged: resolved.merged,
                from: resolved.from,
            });
        }

        // `feature` filters the ROWS, not the instances: an instance that
        // does not carry the named feature is not part of the answer, and
        // the rows that remain are narrowed to it, so the view answers
        let wanted = match &want.feature {
            None => return Ok(rows),
            Some(name) => name.clone(),
        };
        let mut narrowed: Vec<FeatureRow> = Vec::new();
        for row in rows {
            let entry = match jget(&row.merged, &wanted) {
                Some(entry) => entry.clone(),
                None => continue,
            };
            let mut merged: BTreeMap<String, Json> = BTreeMap::new();
            merged.insert(wanted.clone(), entry);
            let mut from: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
            if let Some(slot) = row.from.get(&wanted) {
                from.insert(wanted.clone(), slot.clone());
            }
            narrowed.push(FeatureRow {
                instance: row.instance,
                api: row.api,
                ordered: row
                    .ordered
                    .into_iter()
                    .filter(|name| name == &wanted)
                    .collect(),
                merged: Json::Map(merged),
                from,
            });
        }
        Ok(narrowed)
    }

    /// Eagerly resolve and construct every ACTIVE declared instance - for
    /// CI (design §6.6). The point is to turn availability errors, which
    pub fn check(&self) -> CheckResult {
        let mut out = CheckResult::default();
        for row in self.instances() {
            if !row.active {
                continue;
            }
            self.check_one(&row, &mut out);
        }
        out
    }

    /// guard, a second binding of one instance), and check() exists to
    fn check_one(&self, row: &Instance, out: &mut CheckResult) {
        // with the factory, not with a live client, so a feature typo is
        // a CI failure rather than a setting that quietly did nothing in
        if let Some(entry) = factory_for(&row.api) {
            match self.features_of(&row.name) {
                Err(err) => {
                    out.failed.push(CheckFailure {
                        name: row.name.clone(),
                        code: err.code.clone(),
                        message: err.message(),
                    });
                    return;
                }
                Ok(resolved) => {
                    let faults = check_features(&resolved.merged, &entry.descriptor);
                    if !faults.is_empty() {
                        out.failed.push(CheckFailure {
                            name: row.name.clone(),
                            code: faults[0].code.clone(),
                            message: fault_messages(&faults),
                        });
                        return;
                    }
                }
            }
        }

        let built = catch_unwind(AssertUnwindSafe(|| self.sdk(&row.name)));
        match built {
            Ok(Ok(_client)) => out.ok.push(row.name.clone()),
            Ok(Err(err)) => out.failed.push(CheckFailure {
                name: row.name.clone(),
                code: err.code.clone(),
                message: err.message(),
            }),
            Err(payload) => {
                let text = panic_message(&payload);
                out.failed.push(CheckFailure {
                    name: row.name.clone(),
                    code: code_of(&text),
                    message: text,
                });
            }
        }
    }

    pub fn warm(&self, names: Option<&[String]>) -> WarmResult {
        let wanted: Vec<String> = match names {
            Some(given) => given.to_vec(),
            None => self
                .instances()
                .into_iter()
                .filter(|row| row.active)
                .map(|row| row.name)
                .collect(),
        };

        let mut out = WarmResult::default();

        // included. A NAME NOBODY DECLARED OR REGISTERED IS A MISS, not a
        // lookup - a wider fallback would let a typo like `stripe$prodd`
        let mut bysecret: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for name in wanted {
            let live = self.registry.borrow().get(&name).cloned();
            let declared = self.profile.sdk.contains_key(&name);
            if live.is_none() && !declared {
                out.missed.push(name);
                continue;
            }

            let mut secretname = live.map(|entry| entry.secretname.clone()).unwrap_or_default();
            if secretname.is_empty() {
                secretname = jstr(&self.block_for(&name), "secret");
            }
            if secretname.is_empty() {
                secretname = secretname_default(&self.declared_ref(&name));
            }

            bysecret.entry(secretname).or_default().push(name);
        }

        for (secretname, instances) in bysecret.iter() {
            let ok = self.broker.value(&instances[0], secretname).is_ok();
            for name in instances {
                if ok {
                    out.warmed.push(name.clone());
                } else {
                    out.missed.push(name.clone());
                }
            }
        }

        out.warmed.sort();
        out.missed.sort();
        out
    }

    /// Every DECLARED instance, sorted by name. A different question from
    /// `plugins()`, and the answers differ routinely: a lazily-started
    pub fn instances(&self) -> Vec<Instance> {
        self.profile
            .sdk
            .iter()
            .map(|(name, block)| {
                let live = self.registry.borrow().get(name).cloned();
                Instance {
                    name: name.clone(),
                    api: refapi(name),
                    active: !matches!(jget(block, "active"), Some(Json::Bool(false))),
                    live: live.is_some(),
                    rung: live
                        .map(|entry| entry.rung.clone())
                        .unwrap_or_else(|| "none".to_string()),
                    block: block.clone(),
                }
            })
            .collect()
    }


    /// One entry per LIVE INSTANCE, and EXHAUSTIVE: auto-tagged entries
    /// are NOT collapsed here, because inspection, health reporting and
    /// cleanup all need to enumerate the clients `create()` produced,
    pub fn plugins(&self) -> Vec<PluginInfo> {
        self.registry
            .borrow()
            .values()
            .map(|entry| PluginInfo {
                name: entry.name.clone(),
                api: entry.api.clone(),
                slug: entry.slug.clone(),
                descriptor: entry.descriptor.clone(),
                rung: entry.rung.clone(),
                secretname: entry.secretname.clone(),
                warnings: entry.warnings.clone(),
            })
            .collect()
    }

    pub fn descriptor_of(&self, name: &str) -> Result<Json, StationError> {
        match self.registry.borrow().get(name) {
            Some(entry) => Ok(entry.descriptor.clone()),
            None => Err(StationError::new(
                "station_no_plugin",
                format!(
                    "unknown plugin \"{}\"; known: [{}]",
                    name,
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

    pub fn canonical_descriptor(&self, name: &str) -> Result<String, StationError> {
        Ok(canonical_serialize(&self.descriptor_of(name)?))
    }

    pub fn events(&self) -> Vec<StationEvent> {
        self.buffer.events()
    }

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
                    ("name", jtext(entry.name.clone())),
                    ("api", jtext(entry.api.clone())),
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

    /// close(): flush (solo: nothing in flight), then warn on declared
    /// file (design §11). An ASSIGNED tag counts for the instance it
    /// stands for, which is what `declared_ref` is.
    pub fn close(self: &Rc<Station>) {
        if self.closed.get() {
            return;
        }
        let covered: BTreeSet<String> = self
            .registry
            .borrow()
            .keys()
            .map(|name| self.declared_ref(name))
            .collect();
        for reference in self.profile.sdk.keys() {
            if !covered.contains(reference) {
                self.emit(StationEvent {
                    t: now_ms(),
                    kind: "station".to_string(),
                    meta: Some(jobj(vec![(
                        "warn",
                        jtext(format!(
                            "profile plugin key \"{}\" matched no registered plugin",
                            reference
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

/// A panic payload's text, whether it was a literal or formatted - the
/// message this port's construction-time misconfiguration carries.
fn panic_message(payload: &Box<dyn Any + Send>) -> String {
    if let Some(text) = payload.downcast_ref::<String>() {
        return text.clone();
    }
    if let Some(text) = payload.downcast_ref::<&str>() {
        return text.to_string();
    }
    String::new()
}

fn code_of(text: &str) -> String {
    match text.find(':') {
        Some(at) if is_known_code(&text[..at]) => text[..at].to_string(),
        _ => String::new(),
    }
}

pub(crate) fn policy_allow(block: &Json) -> Option<Json> {
    let allow = match jget(block, "policy").and_then(|policy| jget(policy, "allow")) {
        Some(Json::Map(entries)) => entries,
        _ => return None,
    };
    let mut out: BTreeMap<String, Json> = BTreeMap::new();
    for key in ["op", "method"] {
        if let Some(Json::List(items)) = allow.get(key) {
            let joined: Vec<String> = items.iter().map(jtextof).collect();
            out.insert(key.to_string(), jtext(joined.join(",")));
        }
    }
    if out.is_empty() {
        return None;
    }
    Some(Json::Map(out))
}

pub(crate) fn policy_hosts(block: &Json) -> Option<Vec<String>> {
    match jget(block, "policy").and_then(|policy| jget(policy, "hosts")) {
        Some(Json::List(items)) => Some(
            items
                .iter()
                .filter_map(|item| match item {
                    Json::Str(text) => Some(text.clone()),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    }
}

