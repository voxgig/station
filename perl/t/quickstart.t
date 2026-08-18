# RUN: perl -It t/quickstart.t
#
# The (station.md 11) walkthroughs, run for real: the two-line quickstart
# against a live test API, injection at the transport seam,
# placeholder-safe options_map/prepare, and the event stream. The SDK is
# a REAL generated SDK (taskpad, built by sdkgen from an OpenAPI spec
# with the station feature installed) served by the taskpad test server -
# nothing here is mocked. Mirrors typescript/test/quickstart.test.ts and
# ruby/test/quickstart_test.rb.
#
# The generated SDK loads its VENDORED station library
# (feature/station/lib) by absolute path, so this file deliberately does
# NOT `use Voxgig::Station` from the checkout: the copy the SDK ships is
# the copy under test, and a second load would clobber package state.
#
# Without a generated perl SDK checkout (STATION_TEST_PERL_SDK, or the
# default locations below) it skips rather than fails.

use strict;
use warnings;

use Cwd ();
use File::Basename qw(dirname);
use File::Spec;
use HTTP::Tiny ();
use JSON::PP ();
use Test::More;

my $HERE = dirname( File::Spec->rel2abs(__FILE__) );

my $SDK_ROOT = defined $ENV{STATION_TEST_SDKS}
  ? $ENV{STATION_TEST_SDKS}
  : '/home/user/voxgig-sdk';

my ($SDK_DIR) = grep {
    defined $_ && -e File::Spec->catfile( $_, 'lib', 'TaskpadSDK.pm' )
  } (
    $ENV{STATION_TEST_PERL_SDK},
    File::Spec->catdir( $SDK_ROOT, 'st-perl-sdk',  'perl' ),
    File::Spec->catdir( $SDK_ROOT, 'taskpad-sdk', 'perl' ),
  );

my $SERVER_JS = File::Spec->catfile( $HERE, '..', '..', 'test', 'api',
    'taskpad', 'server.js' );

if ( !defined $SDK_DIR || !-e $SERVER_JS ) {
    plan skip_all => 'no generated perl SDK checkout (set STATION_TEST_PERL_SDK)';
}

my $APIKEY = 'taskpad-key-101';

# Own port: other suites may hold the SDK's default 8902.
my $PORT        = defined $ENV{TASKPAD_PORT} ? $ENV{TASKPAD_PORT} : 8924;
my $BASE        = 'http://localhost:' . $PORT;
my $PLACEHOLDER = '[station:taskpad]';

# Start the taskpad test server (killed in END).
my $SERVER_PID = fork();
die 'fork failed' unless defined $SERVER_PID;
if ( 0 == $SERVER_PID ) {
    $ENV{TASKPAD_PORT}   = $PORT;
    $ENV{TASKPAD_APIKEY} = $APIKEY;
    open( STDOUT, '>', File::Spec->devnull );
    open( STDERR, '>', File::Spec->devnull );
    exec( 'node', $SERVER_JS ) or die "cannot exec node: $!";
}

END {
    if ( $SERVER_PID && 0 != $SERVER_PID ) {

        # waitpid writes the child's wait status into $?, which perl
        # would then use as THIS process's exit code - keep ours.
        local $?;
        kill( 'TERM', $SERVER_PID );
        waitpid( $SERVER_PID, 0 );
    }
}

# Wait for the server to accept connections (any HTTP response is ready).
{
    my $ready = 0;
    for ( 1 .. 50 ) {
        my $res = HTTP::Tiny->new( timeout => 1 )->get( $BASE . '/api/todo' );
        if ( $res->{status} && 599 != $res->{status} ) { $ready = 1; last }
        select( undef, undef, undef, 0.1 );
    }
    die 'taskpad server did not start' unless $ready;
}

# Load the generated SDK - which loads the vendored station library.
require( Cwd::abs_path( File::Spec->catfile( $SDK_DIR, 'lib', 'TaskpadSDK.pm' ) ) );

sub reset_env {
    Voxgig::Station->reset;
    delete $ENV{TASKPAD_APIKEY};
    return;
}

sub events_of {
    my ( $station, $kind ) = @_;
    return [ grep { $kind eq $_->{kind} } @{ $station->events } ];
}

sub events_json {
    my ($station) = @_;
    return JSON::PP->new->allow_blessed(1)->convert_blessed(1)
      ->allow_unknown(1)->encode( $station->events );
}

subtest 'two lines, secret from the documented env var' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect( 'TaskpadSDK', { base => $BASE } );

    my $result = $pad->Todo->list;
    is( ref $result, 'ARRAY', 'list() returns entities' );
    ok( 0 < scalar @$result, 'non-empty' );

    # The op and http events correlate via corr (3, 6).
    my $http = events_of( $station, 'http' );
    my $op   = events_of( $station, 'op' );
    is( scalar @$http, 1, 'one http event' );
    is( scalar @$op,   1, 'one op event' );
    ok( defined $http->[0]{corr}, 'corr present' );
    is( $http->[0]{corr}, $op->[0]{corr}, 'correlated' );
    is( $http->[0]{http}{status}, 200,    'wire status' );
    is( $op->[0]{op}{entity},  'todo', 'entity' );
    is( $op->[0]{op}{op},      'list', 'op' );
    is( $op->[0]{op}{outcome}, 'ok',   'outcome' );

    $station->close;
};

subtest 'options_map and prepare are placeholder-safe (R1)' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect( 'TaskpadSDK', { base => $BASE } );

    # The key is out of app code's way: options_map never exposes the
    # value, prepare output is safe to hand to an agent (5.3, 11).
    is( $pad->options_map->{apikey}, $PLACEHOLDER, 'options placeholder-safe' );

    my $fetchdef = $pad->prepare( { path => '/api/todo', method => 'GET' } );
    my $headers_json = JSON::PP->new->allow_unknown(1)->allow_blessed(1)
      ->encode( $fetchdef->{headers} );
    ok( 0 <= index( $headers_json, $PLACEHOLDER ), 'prepare carries placeholder' );
    ok( 0 > index( $headers_json, $APIKEY ), 'prepare never carries the key' );

    # And the wire still gets the real value.
    my $result = $pad->Todo->list;
    is( ref $result, 'ARRAY', 'live call ok' );

    # No credential anywhere in the event stream either.
    ok( 0 > index( events_json($station), $APIKEY ), 'no key in events' );

    $station->close;
};

subtest 'adopt hoists a resident credential' => sub {
    reset_env();

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->adopt( 'TaskpadSDK', { apikey => $APIKEY, base => $BASE } );

    is( $pad->options_map->{apikey}, $PLACEHOLDER, 'resident replaced' );

    my $result = $pad->Todo->list;
    is( ref $result, 'ARRAY', 'live call ok on hoisted value' );

    my @warns = grep {
        'station' eq $_->{kind}
          && 0 <= index( ( $_->{meta}{warn} || '' ), 'hoisted' )
    } @{ $station->events };
    is( scalar @warns, 1, 'one hoist warning' );

    $station->close;
};

subtest 'a missing secret is station_secret_no_value on the op path' => sub {
    reset_env();

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect( 'TaskpadSDK', { base => $BASE } );

    my $thrown = do {
        local $@;
        eval { $pad->Todo->list };
        $@;
    };
    ok( $thrown, 'op failed' );
    ok( 0 <= index( "$thrown", 'station_secret_no_value' ), 'code in message' );

    my $errs = events_of( $station, 'error' );
    is( scalar @$errs, 1, 'one error event' );
    is( $errs->[0]{err}{code}, 'station_secret_no_value', 'event code' );

    $station->close;
};

subtest 'descriptor carries slug/version/target from the embedded config' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    $station->connect( 'TaskpadSDK', { base => $BASE } );

    my $d = $station->descriptor_of('taskpad');
    is( $d->{slug},     'taskpad', 'slug' );
    is( $d->{envtoken}, 'TASKPAD', 'envtoken' );
    is( $d->{target},   'perl',    'target' );
    is( $d->{version},  '0.0.1',   'version' );
    is( $d->{auth}{secretname}, 'taskpad.apikey', 'secretname default' );
    is_deeply( [ sort keys %{ $d->{entities} } ], ['todo'], 'entities' );
    ok( $d->{entities}{todo}{ops}{list}, 'list op present' );

    # The canonical form serializes (proxy dedupe input).
    is( index( $station->canonical_descriptor('taskpad'), '{"auth":' ), 0,
        'canonical serialization' );

    $station->close;
};

subtest 'test feature stays mocked: no injection into mock transports' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect(
        'TaskpadSDK',
        {
            feature => {
                test => {
                    active => 1,
                    entity => { todo => { t9 => { id => 't9', title => 'mock' } } },
                }
            }
        }
    );

    my $got = $pad->Todo->load( { id => 't9' } )->data_get;
    is( $got->{title}, 'mock', 'mock served' );

    # The http event saw the mock attempt; the placeholder was never
    # swapped (mode ne live), so no real value entered the mock store.
    is( scalar @{ events_of( $station, 'http' ) }, 1, 'mock attempt recorded' );
    ok( 0 > index( events_json($station), $APIKEY ), 'no key near the mock' );

    $station->close;
};

subtest 'inverted binding: SDK->new($station->options)' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $st = Voxgig::Station->open( { config => undef } );

    # The generated constructor, station-built options - the primary
    # binding form for static languages (3.1), exercised here so the
    # GENERATED feature (not the carried adapter) makes the binding.
    my $pad = TaskpadSDK->new( $st->options( { base => $BASE } ) );

    is( $pad->options_map->{apikey}, $PLACEHOLDER, 'placeholder planted' );

    my $result = $pad->Todo->list;
    is( ref $result, 'ARRAY', 'live call ok' );

    my $http = events_of( $st, 'http' );
    my $op   = events_of( $st, 'op' );
    is( scalar @$http, 1, 'one http event' );
    is( scalar @$op,   1, 'one op event' );
    is( $http->[0]{corr}, $op->[0]{corr}, 'correlated' );
    is( $op->[0]{op}{outcome}, 'ok', 'outcome' );

    $st->close;
};

subtest 'connect on the regenerated SDK does not double-bind' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $st = Voxgig::Station->open( { config => undef } );

    # connect() activates the station entry AND rides the carried adapter
    # on extend, so this construction reaches feature_binding twice - the
    # second arrival must be inert (_bound_entry), not an error.
    my $pad = $st->connect( 'TaskpadSDK', { base => $BASE } );

    my @stations =
      grep { 'station' eq $_->get_name } @{ $pad->{features} };
    is( scalar @stations, 2,
        'both the generated feature and the carried adapter are present' );

    is( scalar @{ events_of( $st, 'construct' ) }, 1, 'one construct event' );
    is( scalar @{ $st->plugins },                  1, 'one plugin' );

    my $result = $pad->Todo->list;
    is( ref $result, 'ARRAY', 'live call ok' );

    # One wrap, one hook bridge: no doubled events either.
    is( scalar @{ events_of( $st, 'http' ) }, 1, 'one http event' );
    is( scalar @{ events_of( $st, 'op' ) },   1, 'one op event' );

    $st->close;
};

subtest 'live tap sees traffic' => sub {
    reset_env();
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $st = Voxgig::Station->open( { config => undef } );
    my $pad = $st->connect( 'TaskpadSDK', { base => $BASE } );

    my @seen;
    my $unsub = $st->tap( sub { push @seen, $_[0]->{kind} } );
    $pad->Todo->list;
    $unsub->();

    ok( ( grep { 'http' eq $_ } @seen ), 'tap saw http' );
    ok( ( grep { 'op' eq $_ } @seen ),   'tap saw op' );
    is( $st->status->{mode}, 'solo', 'solo mode' );
    is_deeply( $st->status->{plugins}, [ { slug => 'taskpad', rung => 'R1' } ],
        'status plugins' );

    $st->close;
};

done_testing();
