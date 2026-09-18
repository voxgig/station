
use std::cell::RefCell;
use std::collections::BTreeMap;

use voxgig_sekreto::voxgig_plugin::value::Value as Json;
use voxgig_sekreto::{AuthSpec, Options, ProviderSpec, Sekreto};

use crate::error::StationError;
use crate::jsonx::{jget, jstr};

pub fn placeholder_for(name: &str) -> String {
    format!("[station:{}]", name)
}

pub struct SecretBroker {
    sekreto: RefCell<Sekreto>,
    /// Values hoisted from a resident options.apikey (design §3.1),
    /// keyed by INSTANCE.
    overrides: RefCell<BTreeMap<String, String>>,
    /// Resolved values, keyed by SECRET NAME (§5.3).
    cache: RefCell<BTreeMap<String, String>>,
    /// Every value this broker ever held, for the exact-value scrub.
    held: RefCell<Vec<String>>,
}

impl SecretBroker {
    /// A broker over a profile's provider chain (sekreto ProviderSpec
    /// forms, verbatim - design §5.2). A chain sekreto refuses to build
    /// (a plaintext vault address, an unknown kind) is configuration
    /// error, surfaced as station_secret_error.
    pub fn new(providers: &[Json]) -> Result<SecretBroker, StationError> {
        let specs: Vec<ProviderSpec> = providers.iter().map(providerspec_of).collect();
        let sek = Sekreto::new(Options {
            plugins: voxgig_sekreto_plugins::all(),
            providers: specs,
            nocache: false,
        })
        .map_err(|err| StationError::new("station_secret_error", err.message()))?;
        Ok(SecretBroker {
            sekreto: RefCell::new(sek),
            overrides: RefCell::new(BTreeMap::new()),
            cache: RefCell::new(BTreeMap::new()),
            held: RefCell::new(Vec::new()),
        })
    }

    pub fn hoist(&self, instance: &str, value: &str) {
        self.overrides
            .borrow_mut()
            .insert(instance.to_string(), value.to_string());
        self.held.borrow_mut().push(value.to_string());
    }

    pub fn value(&self, instance: &str, name: &str) -> Result<String, StationError> {
        if let Some(over) = self.overrides.borrow().get(instance) {
            return Ok(over.clone());
        }
        if let Some(cached) = self.cache.borrow().get(name) {
            return Ok(cached.clone());
        }

        let found = self
            .sekreto
            .borrow_mut()
            .trysecret(name)
            .map_err(|err| StationError::new("station_secret_error", err.message))?;

        match found {
            None => Err(StationError::new(
                "station_secret_no_value",
                format!("no store had \"{}\" for plugin \"{}\"", name, instance),
            )),
            Some(value) => {
                self.cache
                    .borrow_mut()
                    .insert(name.to_string(), value.clone());
                self.held.borrow_mut().push(value.clone());
                Ok(value)
            }
        }
    }

    pub fn scrub(&self, text: &str) -> String {
        let mut out = self.sekreto.borrow().redact(text);
        for value in self.held.borrow().iter() {
            if !value.is_empty() {
                out = out
                    .split(value.as_str())
                    .collect::<Vec<&str>>()
                    .join("[redacted]");
            }
        }
        out
    }

    /// Drop caches so the next resolve asks the stores again (rotation
    /// support rides on sekreto's refresh, design §5.3).
    pub fn refresh(&self) {
        self.cache.borrow_mut().clear();
        self.sekreto.borrow_mut().refresh();
    }
}

/// A profile's provider entry (JSON) as sekreto's declarative
/// ProviderSpec. Passed through untouched in spirit (design §11): station
/// neither extends nor validates the fields - every field ProviderSpec
/// has is filled when present, and sekreto's own build errors surface.
fn providerspec_of(val: &Json) -> ProviderSpec {
    let mut spec = ProviderSpec::of(&jstr(val, "kind"));

    spec.name = jstr(val, "name");
    spec.prefix = jstr(val, "prefix");
    spec.file = jstr(val, "file");
    spec.dir = jstr(val, "dir");
    spec.addr = jstr(val, "addr");
    spec.token = jstr(val, "token");
    spec.mount = jstr(val, "mount");
    spec.vaultnamespace = jstr(val, "vaultnamespace");
    spec.command = jstr(val, "command");
    spec.namespace = jstr(val, "namespace");
    spec.home = jstr(val, "home");
    spec.region = jstr(val, "region");
    spec.keyid = jstr(val, "keyid");
    spec.secret = jstr(val, "secret");
    spec.session = jstr(val, "session");
    spec.project = jstr(val, "project");
    spec.vault = jstr(val, "vault");
    spec.tenant = jstr(val, "tenant");
    spec.clientid = jstr(val, "clientid");
    spec.clientsecret = jstr(val, "clientsecret");
    spec.loginaddr = jstr(val, "loginaddr");
    spec.imdsaddr = jstr(val, "imdsaddr");
    spec.metadataaddr = jstr(val, "metadataaddr");
    spec.apiversion = jstr(val, "apiversion");
    spec.config = jstr(val, "config");
    spec.environment = jstr(val, "environment");
    spec.path = jstr(val, "path");

    if let Some(Json::Num(kv)) = jget(val, "kv") {
        spec.kv = *kv as u32;
    }

    if let Some(Json::Map(values)) = jget(val, "values") {
        for (key, entry) in values.iter() {
            if let Json::Str(text) = entry {
                spec.values.insert(key.clone(), text.clone());
            }
        }
    }

    if let Some(auth) = jget(val, "auth") {
        spec.auth = Some(AuthSpec {
            method: jstr(auth, "method"),
            mount: jstr(auth, "mount"),
            role: jstr(auth, "role"),
            jwt: match jget(auth, "jwt") {
                Some(Json::Str(text)) => Some(text.clone()),
                _ => None,
            },
            jwtfile: jstr(auth, "jwtfile"),
            roleid: jstr(auth, "roleid"),
            secretid: jstr(auth, "secretid"),
        });
    }

    spec
}
