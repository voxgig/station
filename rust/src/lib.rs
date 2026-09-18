
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

pub use voxgig_sekreto::voxgig_plugin::value::Value as Json;

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
