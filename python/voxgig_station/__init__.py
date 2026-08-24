# voxgig-station - one control surface for outbound integrations.
#
# A port of typescript/src/index.ts, which is canonical.

from .adapter import FeatureBinding, adapter_feature, feature_binding
from .descriptor import (
    canonical_serialize,
    envtoken,
    normalize_descriptor,
    secretname_default,
)
from .error import StationError, is_known_code
from .factory import factory_for, provide, provided, reset_factories
from .feature import (
    BAND_DEFAULT,
    BAND_STATION,
    BAND_TEST,
    RESERVED_KEYS,
    check_features,
    check_pin,
    compose_features,
    default_band,
    feature_sources,
    merge_features,
    resolve_order,
)
from .loader import (
    DEFAULT_EXPORT,
    camelify,
    check_package,
    factory_from_module,
    load_sync,
)
from .profile import (
    config_scope,
    find_config_file,
    load_config,
    refapi,
    resolve_profile,
    select_profile,
)
from .secrets import placeholder_for
from .shape import (
    BLOCK_DEFAULTS,
    MERGE_SENSITIVE,
    PROFILE_DEFAULTS,
    config_shape,
    normalize_config,
    validate_config,
)
from .station import (
    Station,
    check_instance_name,
    check_instance_tag,
    instance_ref,
)

__all__ = [
    'BAND_DEFAULT',
    'BAND_STATION',
    'BAND_TEST',
    'BLOCK_DEFAULTS',
    'DEFAULT_EXPORT',
    'FeatureBinding',
    'MERGE_SENSITIVE',
    'PROFILE_DEFAULTS',
    'RESERVED_KEYS',
    'Station',
    'StationError',
    'adapter_feature',
    'camelify',
    'canonical_serialize',
    'check_features',
    'check_instance_name',
    'check_instance_tag',
    'check_package',
    'check_pin',
    'compose_features',
    'config_scope',
    'config_shape',
    'default_band',
    'envtoken',
    'factory_for',
    'factory_from_module',
    'feature_binding',
    'feature_sources',
    'find_config_file',
    'instance_ref',
    'is_known_code',
    'load_config',
    'load_sync',
    'merge_features',
    'normalize_config',
    'normalize_descriptor',
    'placeholder_for',
    'provide',
    'provided',
    'refapi',
    'reset_factories',
    'resolve_order',
    'resolve_profile',
    'secretname_default',
    'select_profile',
    'validate_config',
]
