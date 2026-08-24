//! voxgig_station - one control surface for outbound integrations.
//!
//! The Rust port of [station](https://github.com/voxgig/station): solo
//! mode only in v1 (the proxy is a deferred amplifier - design §2.1;
//! `proxy: "require"` fails operations closed with station_no_proxy and
//! `auto` degrades to solo with one warning event). The canonical
//! implementation is typescript/src/*; each module here names the file it
//! ports.
//!
//! Single-threaded by design: the generated Rust SDKs are an Rc/RefCell
//! world (values are neither Send nor Sync, transports are Rc<dyn Fn>),
//! so this library is `!Send` throughout and the ambient instance is
//! thread-local.
//!
//! Binding is the inverted/ambient form only (design §3.1, tier table):
//! open the station, then construct the SDK with the station feature
//! activated in plain options data - the generated adapter (installed by
//! @voxgig/sdkgen-station) binds to the ambient instance:
//!
//! ```ignore
//! use voxgig_station::{Station, StationOptions};
//!
//! let st = Station::open(StationOptions::default());
//! let sdk = taskpad_sdk::TaskpadSDK::new(jo(vec![(
//!     "feature", jo(vec![("station", jo(vec![("active", Value::Bool(true))]))]),
//! )]));
//! // ... sdk.todo(None).list(...) - placeholder-safe options, injected wire
//! st.close();
//! ```

pub mod binding;
pub mod descriptor;
pub mod error;
pub mod events;
pub mod factory;
pub mod feature;
pub mod instance;
pub mod jsonx;
pub mod loader;
pub mod profile;
pub mod secrets;
pub mod shape;
pub mod station;

/// Station's value model IS sekreto's Json - one dependency, one value
/// type (design §10).
pub use voxgig_sekreto::Json;

pub use crate::binding::{bind, hostname, BindSpec, Binding, Bound, TransportPlan};
pub use crate::descriptor::{canonical_serialize, envtoken, normalize_descriptor, secretname_default};
pub use crate::error::{is_known_code, StationError};
pub use crate::events::{ErrEvent, EventBuffer, HttpEvent, OpEvent, StationEvent, TapFn};
pub use crate::factory::{
    factory_for, provide, provided, reset_factories, ConstructFn, Factory, FactoryEntry,
};
pub use crate::feature::{
    active, check_features, check_pin, compose_features, default_band, fault_messages,
    feature_names, feature_sources, merge_features, resolve_order, Fault, Ordered, BAND_DEFAULT,
    BAND_STATION, BAND_TEST, RESERVED_KEYS,
};
pub use crate::instance::{check_instance_name, check_instance_tag, check_ref, instance_ref};
pub use crate::jsonx::{jbool, jget, jlist, jmap, jobj, jstr, jtext, now_ms};
pub use crate::loader::{camelify, check_package, DEFAULT_EXPORT};
pub use crate::profile::{
    block_defaults, config_scope, find_config_file, load_config, refapi, resolve_profile,
    select_profile, ResolvedProfile, MERGE_SENSITIVE,
};
pub use crate::secrets::{placeholder_for, SecretBroker};
pub use crate::shape::{
    config_shape, config_shape_json, normalize_config, profile_defaults, validate_config,
};
pub use crate::station::{
    loose_filter, CheckFailure, CheckResult, ConfigSource, FeatureFilter, FeatureRow, FeatureSet,
    Instance, PluginEntry, PluginInfo, Station, StationOptions, WarmResult,
};
