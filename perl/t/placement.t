# RUN: prove -Ilib -It t/placement.t
#
# A port of typescript/test/placement.test.ts, which is canonical.

use strict;
use warnings;

use JSON::PP ();
use Test::More;

use Voxgig::Station;
use Voxgig::Station::Adapter qw(adapter_anchor);
use Voxgig::Station::Factory qw(provide reset_factories);

# What an SDK generated without the station feature does when it is
# constructed: make_options' feature order, the constructor's loops,
# feature_add's anchors and feature_init, as sdkgen's perl templates
# write them. The perl factory answers a name it has no class for with
# an inert `base` feature. The wire answers one status per attempt.
our @STATUSES;
our @SENT;

our $CONFIG = {
    main    => { name => 'taskpad', slug => 'taskpad', version => '1.0.0', target => 'perl' },
    feature => { cache => {}, retry => {}, test => {} },
    options => { base => 'http://api.test', auth => { prefix => '' } },
    entity  => {},
};

{

    package PlacementFeature;

    sub new { my ( $class, $name ) = @_; return bless { name => $name }, $class }
    sub get_name { return $_[0]->{name} }

    sub init {
        my ( $self, $ctx ) = @_;
        my $inner = $ctx->{utility}{fetcher};
        if ( 'test' eq $self->{name} ) {
            $ctx->{utility}{fetcher} = sub { return ( { status => 200, headers => {} }, undef ) };
        }
        elsif ( 'retry' eq $self->{name} ) {
            $ctx->{utility}{fetcher} = sub {
                my ( $res, $err ) = $inner->(@_);
                for ( 1 .. 2 ) {
                    last if defined $err || 503 != $res->{status};
                    ( $res, $err ) = $inner->(@_);
                }
                return ( $res, $err );
            };
        }
        else {
            $ctx->{utility}{fetcher} = sub { return $inner->(@_) };
        }
        return;
    }
}

sub featureorder {
    my ($fmap) = @_;
    my @names = sort keys %$fmap;
    @names = ( 'test', grep { 'test' ne $_ } @names ) if grep { 'test' eq $_ } @names;
    my ($si) = grep { 'station' eq $names[$_] } 0 .. $#names;
    if ( defined $si ) {
        splice @names, $si, 1;
        my ($ti) = grep { 'test' eq $names[$_] } 0 .. $#names;
        splice @names, ( defined $ti ? $ti + 1 : 0 ), 0, 'station';
    }
    return @names;
}

sub feature_add {
    my ( $features, $f ) = @_;
    my $fopts = $f->{_options} || {};
    for my $i ( 0 .. $#$features ) {
        my $name = $features->[$i]{name};
        next unless defined $name;
        if ( defined $fopts->{__before__} && $fopts->{__before__} eq $name ) {
            splice @$features, $i, 0, $f;
            return;
        }
        if ( defined $fopts->{__after__} && $fopts->{__after__} eq $name ) {
            splice @$features, $i + 1, 0, $f;
            return;
        }
        if ( defined $fopts->{__replace__} && $fopts->{__replace__} eq $name ) {
            $features->[$i] = $f;
            return;
        }
    }
    push @$features, $f;
    return;
}

{

    package PlacementSDK;

    sub new {
        my ( $class, $options ) = @_;
        my $fmap = ref( $options->{feature} ) eq 'HASH' ? $options->{feature} : {};
        my $self = bless {
            mode     => ( ( $fmap->{test} || {} )->{active} ? 'test' : 'live' ),
            features => [],
            options  => $options,
            utility  => {
                fetcher => sub {
                    my ( $ctx, $url ) = @_;
                    push @SENT, $url;
                    my $status = $STATUSES[ $#SENT ] // 200;
                    return ( { status => $status, headers => {} }, undef );
                },
            },
        }, $class;
        my $ctx = {
            client  => $self,
            utility => $self->{utility},
            options => $options,
            config  => $CONFIG,
        };

        for my $fname ( main::featureorder($fmap) ) {
            next unless ( $fmap->{$fname} || {} )->{active};
            my $known = exists $CONFIG->{feature}{$fname};
            main::feature_add( $self->{features}, PlacementFeature->new( $known ? $fname : 'base' ) );
        }
        main::feature_add( $self->{features}, $_ ) for @{ $options->{extend} || [] };
        for my $f ( @{ $self->{features} } ) {
            my $fopts = $fmap->{ $f->get_name };
            $f->init( $ctx, $fopts ) if ref($fopts) eq 'HASH' && $fopts->{active};
        }
        return $self;
    }

    sub list {
        my ($self) = @_;
        my $ctx = {
            client  => $self,
            utility => $self->{utility},
            options => $self->{options},
            config  => $CONFIG,
            op      => { entity => 'todo', name => 'list' },
        };
        $_->can('PrePoint') && $_->PrePoint($ctx) for @{ $self->{features} };
        my ( $res, $err ) =
          $self->{utility}{fetcher}->( $ctx, 'http://api.test/todo', { method => 'GET', headers => {} } );
        $ctx->{result} = { ok => ( !defined $err && 200 == $res->{status} ) ? 1 : 0, err => $err };
        $_->can('PreDone') && $_->PreDone($ctx) for @{ $self->{features} };
        return $res;
    }
}

sub names {
    my ($client) = @_;
    return [ grep { 'base' ne $_ } map { $_->get_name } @{ $client->{features} } ];
}

sub wire {
    my ($station) = @_;
    return [
        map { 'http' eq $_->{kind} ? [ 'http', $_->{http}{status} ] : [ 'op', $_->{op}{outcome} ] }
        grep { 'http' eq $_->{kind} || 'op' eq $_->{kind} } @{ $station->events }
    ];
}

sub fresh {
    my (@statuses) = @_;
    @STATUSES = @statuses;
    @SENT     = ();
    Voxgig::Station->reset;
    reset_factories();
    $ENV{TASKPAD_APIKEY} = 'taskpad-key';
    return;
}

subtest 'after test when test is active, else before the first by name' => sub {
    Voxgig::Station::Struct::structmod();
    is_deeply( adapter_anchor(undef), {} );
    is_deeply( adapter_anchor( {} ), {} );
    is_deeply( adapter_anchor( { station => { active => 1 } } ), {} );
    is_deeply( adapter_anchor( { retry => { active => 1 } } ), { __before__ => 'retry' } );
    is_deeply( adapter_anchor( { retry => { active => 1 }, cache => { active => 1 } } ),
        { __before__ => 'cache' } );
    is_deeply( adapter_anchor( { cache => { active => 0 }, retry => { active => 1 } } ),
        { __before__ => 'retry' } );
    is_deeply( adapter_anchor( { station => { active => 1 }, timeout => { active => 1 } } ),
        { __before__ => 'timeout' } );
    is_deeply( adapter_anchor( { test => { active => 1 }, retry => { active => 1 } } ),
        { __after__ => 'test' } );
    is_deeply( adapter_anchor( { test => { active => 0 }, retry => { active => 1 } } ),
        { __before__ => 'retry' } );
    is_deeply( adapter_anchor( { retry => { active => JSON::PP::true } } ), { __before__ => 'retry' } );
    is_deeply( adapter_anchor( { retry => { active => JSON::PP::false } } ), {} );
    is_deeply( adapter_anchor( { retry => { active => Voxgig::Struct::JTRUE() } } ),
        { __before__ => 'retry' } );
    is_deeply( adapter_anchor( { retry => { active => Voxgig::Struct::JFALSE() } } ), {} );
    is_deeply( adapter_anchor( { retry => { active => [1] } } ), {} );
    # sdkgen's ordered array form: array order is init order.
    is_deeply( adapter_anchor( [ { name => 'retry', active => 1 } ] ),
        { __before__ => 'retry' } );
    is_deeply(
        adapter_anchor( [ { name => 'retry', active => 1 }, { name => 'cache', active => 1 } ] ),
        { __before__ => 'retry' } );
    is_deeply(
        adapter_anchor( [ { name => 'retry', active => 1 }, { name => 'test', active => 1 } ] ),
        { __after__ => 'test' } );
    is_deeply( adapter_anchor( [ { name => 'station', active => 1 }, { name => 'retry' } ] ),
        {} );
};

subtest 'live, with retry: station is the base wrap and sees each attempt' => sub {
    fresh( 503, 200 );
    my $st     = Voxgig::Station->new( { config => undef } );
    my $client = $st->connect( 'PlacementSDK', { feature => { retry => { active => 1 } } } );

    is_deeply( names($client), [qw(station retry)] );
    $client->list;
    is( scalar @SENT, 2 );
    is_deeply( wire($st), [ [ 'http', 503 ], [ 'http', 200 ], [ 'op', 'ok' ] ] );
    $st->close;
};

subtest 'live, with two features: station comes before the first by name' => sub {
    fresh();
    my $st     = Voxgig::Station->new( { config => undef } );
    my $client = $st->adopt( 'PlacementSDK',
        { feature => { retry => { active => 1 }, cache => { active => 1 } } } );
    is_deeply( names($client), [qw(station cache retry)] );
    $st->close;
};

subtest 'test mode: station sits on the mock transport' => sub {
    fresh();
    my $st     = Voxgig::Station->new( { config => undef } );
    my $client = $st->connect( 'PlacementSDK',
        { feature => { test => { active => 1 }, retry => { active => 1 } } } );
    is_deeply( names($client), [qw(test station retry)] );
    $st->close;
};

subtest 'no other feature: station alone' => sub {
    fresh();
    my $st = Voxgig::Station->new( { config => undef } );
    is_deeply( names( $st->connect( 'PlacementSDK', {} ) ), ['station'] );
    $st->close;
};

subtest 'the declarative path places it the same way' => sub {
    fresh( 503, 200 );
    provide( 'taskpad', { construct => sub { PlacementSDK->new(@_) }, config => $CONFIG } );
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => { default => { sdk => { taskpad => { feature => { retry => {} } } } } },
            },
        }
    );
    my $client = $st->sdk('taskpad');

    is_deeply( names($client), [qw(station retry)] );
    $client->list;
    is( scalar @SENT, 2 );
    is_deeply( wire($st), [ [ 'http', 503 ], [ 'http', 200 ], [ 'op', 'ok' ] ] );
    $st->close;
};

Voxgig::Station->reset;
reset_factories();
delete $ENV{TASKPAD_APIKEY};

done_testing;
