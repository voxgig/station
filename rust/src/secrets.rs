
use std::cell::RefCell;
use std::collections::BTreeMap;

use voxgig_sekreto::voxgig_plugin::value::Value as Json;
use voxgig_sekreto::{AuthSpec, Options, ProviderSpec, Sekreto};

use crate::error::StationError;
use crate::jsonx::{jget, jstr};

pub fn placeholder_for(name: &str) -> String {
    format!("[station:{}]", name)
}

/// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
pub fn encode_query_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{:02X}", byte));
        }
    }
    out
}

fn match_at(text: &[u8], at: usize, end: usize, placeholder: &[u8]) -> Option<usize> {
    let hexval = |byte: u8| (byte as char).to_digit(16);
    let mut i = at;
    for &ch in placeholder {
        if i < end && text[i] == ch {
            i += 1;
            continue;
        }
        if i + 3 <= end && b'%' == text[i] {
            if let (Some(hi), Some(lo)) = (hexval(text[i + 1]), hexval(text[i + 2])) {
                if u32::from(ch) == hi * 16 + lo {
                    i += 3;
                    continue;
                }
            }
        }
        return None;
    }
    Some(i - at)
}

/// The placeholder becomes the value in header values and in the URL
/// query, where an SDK percent-encodes it (any hex case) and the value is
/// encoded in turn. The path and fragment are never touched; the headers
/// are a copy.
pub fn substitute(
    url: &str,
    headers: &BTreeMap<String, String>,
    placeholder: &str,
    value: &str,
) -> (String, BTreeMap<String, String>) {
    let mut out = headers.clone();
    if placeholder.is_empty() {
        return (url.to_string(), out);
    }
    for entry in out.values_mut() {
        if entry.contains(placeholder) {
            *entry = entry.replace(placeholder, value);
        }
    }

    let query = match url.find('?') {
        Some(at) => at + 1,
        None => return (url.to_string(), out),
    };
    let end = url[query..]
        .find('#')
        .map_or(url.len(), |hash| query + hash);
    let encoded = encode_query_value(value);
    let mut sent = url[..query].to_string();
    let (mut copied, mut at) = (query, query);
    while at < end {
        match match_at(url.as_bytes(), at, end, placeholder.as_bytes()) {
            Some(len) if 0 < len => {
                sent.push_str(&url[copied..at]);
                sent.push_str(&encoded);
                at += len;
                copied = at;
            }
            _ => at += 1,
        }
    }
    sent.push_str(&url[copied..]);
    (sent, out)
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
                let encoded = encode_query_value(value);
                if encoded != *value {
                    out = out
                        .split(encoded.as_str())
                        .collect::<Vec<&str>>()
                        .join("[redacted]");
                }
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
