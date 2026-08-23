package Voxgig::Station::Error;

# Error codes follow the SDKs' house grammar (design station.md 14):
# <subject>_<condition>, absence as no_<thing>, gates as _allow.
# The `errors` corpus section pins the exact strings.
#
# A port of typescript/src/error.ts, which is canonical.

use strict;
use warnings;

use JSON::PP ();

use Exporter 'import';
our @EXPORT_OK = qw(is_known_code);

my @CODES = qw(
  station_no_proxy
  station_secret_no_value
  station_secret_error
  station_secret_name
  station_host_allow
  station_grant_expired
  station_wrap_order
  station_protocol
  station_no_plugin
  station_no_entity
  station_no_op
  station_agent_allow
  station_body_limit
  station_replay_lossy
  station_open_conflict
  station_bound_twice

  # Declarative config (design 6.4). Only the reference ports raise
  # the config-validation codes so far (Stage 1); the catalog is
  # repo-wide, so every port knows them.
  station_config_invalid
  station_config_secret
  station_secret_collision
  station_feature_reserved

  # Instances (design 6.4). `as` is a tag, not a free name.
  station_instance_api

  # The declarative front door (design 6.4). Availability errors are
  # fatal at first use, not at open().
  station_no_instance
  station_instance_inactive
  station_sdk_load
  station_no_factory
  station_factory_conflict

  # Features (design 8.4, 8.5).
  station_feature_unknown
  station_feature_option
  station_feature_order
);

my %KNOWN = map { $_ => 1 } @CODES;

# A JSON boolean, so the answer survives serialization boundaries (and
# the conformance corpus) without Perl's untyped-scalar ambiguity.
sub is_known_code {
    my ($code) = @_;
    return ( defined $code && !ref $code && $KNOWN{$code} )
      ? JSON::PP::true
      : JSON::PP::false;
}

# The station error object. Its message CARRIES the code ("<code>: <msg>",
# the ts StationError shape), so the code survives even when only the
# stringification rides an SDK's own error path.
{

    package Voxgig::Station::StationError;

    use overload
      '""'     => sub { $_[0]->{message} },
      'bool'   => sub { 1 },
      fallback => 1;

    sub new {
        my ( $class, $code, $message ) = @_;
        return bless {
            code    => ( defined $code ? $code : '' ),
            message => ( defined $code ? $code . ': ' : '' )
              . ( defined $message ? $message : '' ),
        }, $class;
    }

    sub code    { return $_[0]->{code} }
    sub message { return $_[0]->{message} }
}

sub fail {
    my ( $code, $message ) = @_;
    die Voxgig::Station::StationError->new( $code, $message );
}

1;
