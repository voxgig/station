//! The secret broker (design §5): sekreto resolves, station places. The
//! broker holds resolved values privately - they never enter options,
//! events, or captures; the SDK sees only the placeholder.
//!
//! A port of typescript/src/secrets.ts, which is canonical. Where the
//! canonical broker string-matches sekreto's thrown 'unknown secret', this
//! port uses the Rust sekreto's own miss-vs-error split (`trysecret`
//! returns Ok(None) for a miss, Err for a store that could not answer) -
//! the same distinction, natively typed.

use std::cell::RefCell;
use std::collections::BTreeMap;

use voxgig_sekreto::{makechain, AuthSpec, Json, ProviderSpec, Sekreto};

use crate::error::StationError;
use crate::jsonx::{jget, jstr};

/// The inert value planted in options.apikey (design §5.3 R1). The
/// `placeholder` corpus section pins the exact string.
///
/// §7.2: KEYED BY INSTANCE. Two live instances of one api must have
/// distinct placeholders or the injection seam cannot tell which
/// credential a header wants. For an untagged instance this is the api
/// slug, so the single-instance case is unchanged.
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
        let chain = makechain(&specs)
            .map_err(|err| StationError::new("station_secret_error", err.message))?;
        Ok(SecretBroker {
            sekreto: RefCell::new(Sekreto::new(chain)),
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

    /// Resolve the value for an instance's secret name. Misses and store
    /// errors keep sekreto's distinction (design §5.2): a miss is
    /// station_secret_no_value, a store that could not answer is
    /// station_secret_error with sekreto's message intact - and never a
    /// retry against a weaker store (sekreto owns the chain).
    ///
    /// OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
    /// SECRET NAME (§5.3). A hoisted credential belongs to the one
    /// instance it was resident in, but a resolved VALUE belongs to the
    /// name it was resolved for - so several instances sharing one
    /// api-level `secret` cost one lookup rather than one each, and every
    /// client an auto-tagged create() produces shares the declared
    /// instance's entry instead of re-resolving per request. Keying the
    /// cache by instance instead is the defect this replaces: at 26
    /// instances over 20 apis it turns one store round-trip into 26.
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

    /// Exact-value scrub, deliberately WITHOUT sekreto's four-character
    /// readability floor (design §7 as revised): on boundaries where the
    /// promise is absolute, every held value is scrubbed whatever its
    /// length. sekreto's own redact() runs too, covering values resolved
    /// by the underlying instance that station never held.
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
