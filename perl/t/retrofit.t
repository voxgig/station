# RUN: prove -Ilib -It t/retrofit.t
#
# A port of typescript/test/retrofit.test.ts, which is canonical: an SDK
# generated without the station feature, as connect() and adopt()
# retrofit it, against a server whose first answer is a 503. Such an SDK
# ships no station, so the one under test is this checkout's.

use strict;
use warnings;

use Cwd ();
use File::Basename qw(dirname);
use File::Spec;
use HTTP::Tiny ();
use Test::More;

my $HERE = dirname( File::Spec->rel2abs(__FILE__) );

my $SDK_ROOT = defined $ENV{STATION_TEST_SDKS} ? $ENV{STATION_TEST_SDKS} : '/home/user/voxgig-sdk';
my $SDK_DIR  = File::Spec->catdir( $SDK_ROOT, 'taskpad-plain-sdk', 'perl' );
my $SERVER_JS = File::Spec->catfile( $HERE, '..', '..', 'test', 'api', 'taskpad', 'server.js' );

if ( !-e File::Spec->catfile( $SDK_DIR, 'lib', 'TaskpadSDK.pm' ) || !-e $SERVER_JS ) {
    BAIL_OUT('STATION_REQUIRE_SDKS is set but there is no generated perl SDK - run `make fixtures`')
      if $ENV{STATION_REQUIRE_SDKS};
    plan skip_all => 'no generated perl SDK without the station feature';
}

my $APIKEY = 'taskpad-key-101';
my $PORT   = 8945;
my $BASE   = 'http://localhost:' . $PORT;

my $SERVER_PID = fork();
die 'fork failed' unless defined $SERVER_PID;
if ( 0 == $SERVER_PID ) {
    $ENV{TASKPAD_PORT}   = $PORT;
    $ENV{TASKPAD_APIKEY} = $APIKEY;
    $ENV{TASKPAD_FAIL}   = 1;
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

{
    my $ready = 0;
    for ( 1 .. 50 ) {
        my $res = HTTP::Tiny->new( timeout => 1 )->get( $BASE . '/api/todo' );
        if ( $res->{status} && 599 != $res->{status} ) { $ready = 1; last }
        select( undef, undef, undef, 0.1 );
    }
    die 'taskpad server did not start' unless $ready;
}

require Voxgig::Station;
require( Cwd::abs_path( File::Spec->catfile( $SDK_DIR, 'lib', 'TaskpadSDK.pm' ) ) );

subtest 'live, with retry: station wraps the wire and sees each attempt' => sub {
    Voxgig::Station->reset;
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect( 'TaskpadSDK',
        { base => $BASE, feature => { retry => { active => 1 } } } );

    is_deeply( [ grep { 'base' ne $_ } map { $_->get_name } @{ $pad->{features} } ],
        [qw(station retry)] );

    my $todos = $pad->Todo->list;
    ok( 0 < scalar @$todos, 'list() returns records' );

    my @events = grep { 'http' eq $_->{kind} || 'op' eq $_->{kind} } @{ $station->events };
    is_deeply(
        [ map { 'http' eq $_->{kind} ? [ 'http', $_->{http}{status} ] : [ 'op', $_->{op}{outcome} ] } @events ],
        [ [ 'http', 503 ], [ 'http', 200 ], [ 'op', 'ok' ] ]
    );
    my %corr = map { $_->{corr} => 1 } @events;
    is( scalar keys %corr, 1, 'one correlation id' );

    $station->close;
    Voxgig::Station->reset;
};

# sdkgen's ordered array form: position is init order, so station takes its
# pinned place first rather than the caller's map spread.
subtest 'the array form of options.feature binds, with retry outside station' => sub {
    Voxgig::Station->reset;
    local $ENV{TASKPAD_APIKEY} = $APIKEY;

    my $station = Voxgig::Station->open( { config => undef } );
    my $pad = $station->connect( 'TaskpadSDK',
        { base => $BASE, feature => [ { name => 'retry', active => 1 } ] } );

    is_deeply( [ grep { 'base' ne $_ } map { $_->get_name } @{ $pad->{features} } ],
        [qw(station retry)] );

    my $todos = $pad->Todo->list;
    ok( 0 < scalar @$todos, 'list() returns records' );

    my @events = grep { 'http' eq $_->{kind} || 'op' eq $_->{kind} } @{ $station->events };
    my @wire =
      map { 'http' eq $_->{kind} ? [ 'http', $_->{http}{status} ] : [ 'op', $_->{op}{outcome} ] }
      @events;
    is_deeply( [ @wire[ -2, -1 ] ], [ [ 'http', 200 ], [ 'op', 'ok' ] ] );

    $station->close;
    Voxgig::Station->reset;
};

done_testing;
