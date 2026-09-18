
use std::fmt;

const CODES: &[&str] = &[
    "station_no_proxy",
    "station_secret_no_value",
    "station_secret_error",
    "station_secret_name",
    "station_host_allow",
    "station_grant_expired",
    "station_wrap_order",
    "station_protocol",
    "station_no_plugin",
    "station_no_entity",
    "station_no_op",
    "station_agent_allow",
    "station_body_limit",
    "station_replay_lossy",
    "station_open_conflict",
    "station_bound_twice",

    // Declarative config (design §6.4). Only the reference ports raise
    // the config-validation codes so far (Stage 1); the catalog is
    // repo-wide, so every port knows them.
    "station_config_invalid",
    "station_config_secret",
    "station_secret_collision",
    "station_feature_reserved",

    // Instances (design §6.4). `as` is a tag, not a free name.
    "station_instance_api",

    "station_no_instance",
    "station_instance_inactive",
    "station_sdk_load",
    "station_no_factory",
    "station_factory_conflict",

    // Features (design §8.4, §8.5).
    "station_feature_unknown",
    "station_feature_option",
    "station_feature_order",
];

#[derive(Clone, Debug, PartialEq)]
pub struct StationError {
    pub code: String,
    pub msg: String,
}

impl StationError {
    pub fn new(code: &str, msg: impl Into<String>) -> StationError {
        StationError {
            code: code.to_string(),
            msg: msg.into(),
        }
    }

    /// The full message, the way the canonical port's Error.message reads:
    /// `code: message`.
    pub fn message(&self) -> String {
        format!("{}: {}", self.code, self.msg)
    }
}

impl fmt::Display for StationError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", self.message())
    }
}

impl std::error::Error for StationError {}

pub fn is_known_code(code: &str) -> bool {
    CODES.contains(&code)
}
