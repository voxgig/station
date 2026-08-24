# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/station.t
#
# Focused unit tests for the parts the corpus cannot express without an
# SDK: the binding (wrap position, placeholder planting, hoist), the
# transport middleware (copy-on-inject, mock skip, status-0 mapping,
# hosts policy + manual redirects, require-proxy fail-closed, secret
# miss), and the event surface. A miniature duck-typed SDK stands in for
# a generated one, mirroring the generated perl feature-test harness
# idiom (plain hashes for client/utility/ctx, ($response, $err) tuples).

use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(refaddr);
use Test::More;

use Voxgig::Station;
use Voxgig::Station::Error qw(is_known_code);
use Voxgig::Station::Adapter qw(adapter_feature feature_binding);
use Voxgig::Station::Factory qw(factory_for provide provided reset_factories);
use Voxgig::Station::Feature qw(RESERVED_KEYS checkfeatures);
use Voxgig::Station::Loader qw(camelify check_package factory_from_module);
use Voxgig::Station::Secrets qw(placeholder_for);
use Voxgig::Station::Profile qw(select_profile);
use Voxgig::Station::Shape qw(
  BLOCK_DEFAULTS MERGE_SENSITIVE PROFILE_DEFAULTS config_shape normalize_config
);
use Voxgig::Station::Struct qw(mapkeys);

my $CONFIG = {
    main => {
        name    => 'GnarlyPets',
        slug    => 'gnarly-pets',
        version => '0.0.1',
        target  => 'perl',
    },
    feature => { test => {} },
    options => {
        base   => 'http://localhost:8903',
        auth   => { prefix => 'Bearer' },
        entity => { pet => {} },
    },
    entity => {},
};

my $PLACEHOLDER = '[station:gnarly-pets]';

sub okres {
    my ( $status, $headers ) = @_;
    return {
        status     => defined $status ? $status : 200,
        statusText => 'OK',
        headers    => defined $headers ? $headers : {},
        json       => sub { undef },
        body       => '',
    };
}

# Build a bound miniature client: station feature first (bare SDK), a
# stub inner transport, and the station wrap installed by
# feature_binding.
sub bind_client {
    my ( $station, $inner, $opts ) = @_;
    $opts = {} unless defined $opts;

    my $client  = { mode => 'live', features => [], options => undef };
    my $utility = { fetcher => $inner };

    my $options = {
        apikey  => defined $opts->{apikey} ? $opts->{apikey} : '',
        base    => 'http://localhost:8903',
        feature => { station => { active => 1 } },
    };
    $client->{options} = $options;

    my $ctx = {
        client  => $client,
        utility => $utility,
        options => $options,
        config  => defined $opts->{config} ? $opts->{config} : {%$CONFIG},
    };

    my $feature =
      adapter_feature( $station, defined $opts->{calleropts} ? $opts->{calleropts} : {} );
    push @{ $client->{features} }, @{ $opts->{pre_features} || [] };
    push @{ $client->{features} }, $feature;
    push @{ $client->{features} }, @{ $opts->{post_features} || [] };

    my $fopts = { %{ $options->{feature}{station} } };
    $feature->init( $ctx, $fopts );

    return {
        client  => $client,
        utility => $utility,
        ctx     => $ctx,
        feature => $feature,
        options => $options,
    };
}

sub events_of {
    my ( $station, $kind ) = @_;
    return [ grep { $kind eq $_->{kind} } @{ $station->events } ];
}

sub reset_env {
    Voxgig::Station->reset;

    # The factory table is PROCESS-GLOBAL by design (6.2 path 1 is module
    # self-registration, which happens once per process), so a suite that
    # registers factories has to be able to put the process back.
    reset_factories();
    delete $ENV{GNARLY_PETS_APIKEY};
    delete $ENV{VOXGIG_STATION_PROFILE};
    return;
}

# A miniature GENERATED SDK for the declarative front door: a
# module-level config constant beside a constructor that runs the
# `extend` features the way a generated constructor does. Deliberately a
# PRE-STATION SDK (its own config declares no station feature), which is
# the 3.1 retrofit case build() has to carry the adapter for.
{

    package StubSDK;

    our $CONFIG = {
        main => {
            name    => 'GnarlyPets',
            slug    => 'gnarly-pets',
            version => '0.0.1',
            target  => 'perl',
        },
        feature => {
            retry => { options => { retries => 1, wait => 100 } },
            test  => {},
        },
        options => {
            base   => 'http://localhost:8903',
            auth   => { prefix => 'Bearer' },
            entity => { pet => {} },
        },
        entity => {},
    };

    sub config { return $CONFIG }

    sub new {
        my ( $class, $options ) = @_;
        my $self = bless {
            mode     => 'live',
            features => [],
            options  => { %{ $options || {} } },
        }, $class;

        $self->{utility} =
          { fetcher => sub { return ( main::okres(), undef ) } };
        $self->{ctx} = {
            client  => $self,
            utility => $self->{utility},
            options => $self->{options},
            config  => $CONFIG,
        };

        my $fopts = $self->{options}{feature}{station};
        for my $feature ( @{ $self->{options}{extend} || [] } ) {
            push @{ $self->{features} }, $feature;
            $feature->init( $self->{ctx}, { %{ $fopts || {} } } );
        }
        return $self;
    }
}

sub stub_factory {
    return {
        construct => sub { return StubSDK->new( $_[0] ) },
        config    => $StubSDK::CONFIG,
    };
}

# --- ambient instance (design station.md 10.2) ---

subtest 'open is idempotent and conflicts error' => sub {
    reset_env();
    my $a = Voxgig::Station->open( { config => undef } );
    my $b = Voxgig::Station->open( { config => undef } );
    is( refaddr($a), refaddr($b), 'same instance' );
    my $err = do {
        local $@;
        eval { Voxgig::Station->open( { config => undef, profile => 'prod' } ) };
        $@;
    };
    is( $err->code, 'station_open_conflict', 'conflicting open errors' );
    is( refaddr( Voxgig::Station->current ), refaddr($a), 'current is ambient' );
    Voxgig::Station->reset;
    is( Voxgig::Station->current, undef, 'reset drops ambient' );
};

subtest 'close resets ambient and warns unmatched plugin keys' => sub {
    reset_env();
    my $st = Voxgig::Station->open(
        {
            config => {
                station  => 1,
                profiles => {
                    default =>
                      { sdk => { 'typo-slug' => { base => 'http://x' } } }
                },
            }
        }
    );
    $st->close;
    my @warns = grep {
        'station' eq $_->{kind}
          && 0 <= index( ( $_->{meta}{warn} || '' ), 'typo-slug' )
    } @{ $st->events };
    is( scalar @warns, 1, 'one warning' );
    is( Voxgig::Station->current, undef, 'close resets ambient' );
};

# --- binding (design station.md 3) ---

subtest 'binding plants placeholder and registers' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'k-123';
    my $st = Voxgig::Station->new( { config => undef } );
    my $b = bind_client( $st, sub { return ( okres(), undef ) } );

    is( $b->{options}{apikey}, $PLACEHOLDER, 'placeholder planted' );
    is( scalar @{ $st->plugins }, 1, 'one plugin' );
    is( $st->plugins->[0]{slug}, 'gnarly-pets', 'slug' );
    is( $st->plugins->[0]{rung}, 'R1',          'rung' );
    is( scalar @{ events_of( $st, 'construct' ) }, 1, 'construct event' );
    is( $st->descriptor_of('gnarly-pets')->{target}, 'perl', 'descriptor target' );
};

subtest 'binding hoists a resident credential' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );
    my $seen;
    my $b = bind_client(
        $st,
        sub {
            my ( $fctx, $fullurl, $fetchdef ) = @_;
            $seen = $fetchdef->{headers}{authorization};
            return ( okres(), undef );
        },
        { apikey => 'r7' }
    );

    is( $b->{options}{apikey}, $PLACEHOLDER, 'placeholder planted over resident' );
    my @warns = grep {
        'station' eq $_->{kind}
          && 0 <= index( ( $_->{meta}{warn} || '' ), 'hoisted' )
    } @{ $st->events };
    is( scalar @warns, 1, 'hoist warning' );

    # The hoisted value is injected on the wire without any store.
    my ( $res, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx},
        'http://localhost:8903/x',
        { method => 'GET', headers => { authorization => 'Bearer ' . $PLACEHOLDER } }
    );
    is( $err, undef, 'no error' );
    is( $res->{status}, 200, 'ok' );
    is( $seen, 'Bearer r7', 'hoisted value injected' );

    # ...and the scrub covers it, whatever its length (no 4-char floor -
    # sekreto's own redact would leave a 2-char value in place).
    is( $st->redact('r7'), '[redacted]', 'exact-value scrub, no floor' );
};

subtest 'wrap order guard trips when a wrapper precedes' => sub {
    reset_env();
    my $st  = Voxgig::Station->new( { config => undef } );
    my $err = do {
        local $@;
        eval {
            bind_client( $st, sub { return ( okres(), undef ) },
                { pre_features => [ { name => 'retry' } ] } );
        };
        $@;
    };
    is( $err->code, 'station_wrap_order', 'guard trips' );
};

subtest 'wrap order guard ignores inert base strays' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );

    # The generated feature factory falls back to a base feature for
    # unknown names (a pre-station SDK given an active station entry) -
    # the stray can never wrap, so the guard excludes it.
    my $b = bind_client( $st, sub { return ( okres(), undef ) },
        { pre_features => [ { name => 'base' } ] } );
    is( scalar @{ $st->plugins }, 1, 'bound' );
    is( $b->{options}{apikey}, $PLACEHOLDER, 'placeholder planted' );
};

subtest 'second bind of same client is inert' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );
    my $b = bind_client( $st, sub { return ( okres(), undef ) } );

    my $second = adapter_feature( $st, {} );
    push @{ $b->{client}{features} }, $second;
    $second->init( $b->{ctx}, { %{ $b->{options}{feature}{station} } } );

    is( scalar @{ $st->plugins }, 1, 'still one plugin' );
    ok( Voxgig::Station::Adapter::_is_station_wrap( $b->{utility}{fetcher} ),
        'single wrap retained' );
};

subtest 'binding a second client of the same slug errors' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );
    bind_client( $st, sub { return ( okres(), undef ) } );
    my $err = do {
        local $@;
        eval { bind_client( $st, sub { return ( okres(), undef ) } ) };
        $@;
    };
    is( $err->code, 'station_bound_twice', 'slug check' );
};

subtest 'profile base applied unless caller base wins' => sub {
    reset_env();
    my $config = {
        station  => 1,
        profiles => {
            default =>
              { sdk => { 'gnarly-pets' => { base => 'http://profile:9' } } }
        },
    };
    my $st = Voxgig::Station->new( { config => $config } );
    my $b = bind_client( $st, sub { return ( okres(), undef ) },
        { calleropts => {} } );
    is( $b->{options}{base}, 'http://profile:9', 'profile base applied' );

    my $st2 = Voxgig::Station->new( { config => $config } );
    my $b2  = bind_client(
        $st2,
        sub { return ( okres(), undef ) },
        { calleropts => { base => 'http://caller:7' } }
    );
    is( $b2->{options}{base}, 'http://localhost:8903', 'caller base wins' );
};

# --- the transport middleware (design station.md 3.3, 5.3) ---

subtest 'copy-on-inject' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'wire-key-9';
    my $st = Voxgig::Station->new( { config => undef } );
    my $seen;
    my $b = bind_client(
        $st,
        sub {
            my ( $fctx, $fullurl, $fetchdef ) = @_;
            $seen = $fetchdef;
            return ( okres( 200, { 'content-length' => '12' } ), undef );
        }
    );

    my $fetchdef = {
        method  => 'GET',
        headers => { authorization => 'Bearer ' . $PLACEHOLDER },
    };
    $b->{feature}->PrePoint( $b->{ctx} );
    my ( $res, $err ) =
      $b->{utility}{fetcher}->( $b->{ctx}, 'http://localhost:8903/api/pet', $fetchdef );

    is( $err, undef, 'no error' );
    is( $res->{status}, 200, 'ok' );

    # The wire got the real value...
    is( $seen->{headers}{authorization}, 'Bearer wire-key-9', 'injected' );

    # ...and the caller-visible fetchdef still holds the placeholder
    # (copy-on-inject: ctrl.explain / ctx.spec share this hash).
    is( $fetchdef->{headers}{authorization}, 'Bearer ' . $PLACEHOLDER,
        'placeholder kept' );
    isnt( refaddr( $fetchdef->{headers} ), refaddr( $seen->{headers} ),
        'headers were copied' );

    # The http event is wire truth, correlated with the op.
    $b->{ctx}{op}     = { entity => 'pet', name => 'list' };
    $b->{ctx}{result} = { ok     => 1 };
    $b->{feature}->PreDone( $b->{ctx} );

    my $http = events_of( $st, 'http' );
    my $op   = events_of( $st, 'op' );
    is( scalar @$http, 1, 'one http event' );
    is( scalar @$op,   1, 'one op event' );
    is( $http->[0]{corr}, $op->[0]{corr}, 'correlated' );
    is( $http->[0]{http}{status}, 200,              'status' );
    is( $http->[0]{http}{bytes},  12,               'bytes' );
    is( $http->[0]{http}{host},   'localhost:8903', 'host keeps port' );
    is( $http->[0]{http}{path},   '/api/pet',       'path' );
    is( $op->[0]{op}{entity},  'pet',  'entity' );
    is( $op->[0]{op}{op},      'list', 'op' );
    is( $op->[0]{op}{outcome}, 'ok',   'outcome' );

    # No credential anywhere in the event stream.
    my $blob = JSON::PP->new->allow_blessed(1)->convert_blessed(1)
      ->allow_unknown(1)->encode( $st->events );
    ok( 0 > index( $blob, 'wire-key-9' ), 'no credential in events' );
};

subtest 'no injection into mock transports' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'never-on-mock';
    my $st = Voxgig::Station->new( { config => undef } );
    my $seen;
    my $b = bind_client(
        $st,
        sub {
            my ( $fctx, $fullurl, $fetchdef ) = @_;
            $seen = $fetchdef->{headers}{authorization};
            return ( okres(), undef );
        }
    );

    $b->{client}{mode} = 'test';
    my ( undef, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx},
        'http://localhost:8903/x',
        { method => 'GET', headers => { authorization => 'Bearer ' . $PLACEHOLDER } }
    );
    is( $err, undef, 'no error' );

    # Placeholder rides through untouched; the http event still records
    # the mock attempt.
    is( $seen, 'Bearer ' . $PLACEHOLDER, 'no injection' );
    is( scalar @{ events_of( $st, 'http' ) }, 1, 'mock attempt recorded' );
};

subtest 'status-0 is a transport failure' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'status-zero-key';
    my $st = Voxgig::Station->new( { config => undef } );
    my $b = bind_client(
        $st,
        sub {
            return (
                {
                    status     => 0,
                    statusText => 'Connection refused: boom',
                    headers    => {},
                    json       => sub { undef },
                    body       => undef,
                },
                undef
            );
        }
    );

    my ( $res, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx}, 'http://localhost:8903/x', { method => 'GET', headers => {} }
    );
    is( $err, undef, 'tuple err stays undef' );
    is( $res->{status}, 0, 'status 0 response' );

    my $http = events_of( $st, 'http' );
    my $errs = events_of( $st, 'error' );
    is( scalar @$http, 1, 'one http event' );
    is( $http->[0]{http}{status}, 0, 'http status 0' );
    is( scalar @$errs, 1, 'one error event' );
    ok( 0 <= index( $errs->[0]{err}{message}, 'Connection refused' ),
        'statusText surfaced' );
};

subtest 'hosts policy denies off-list egress and forces manual redirects' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'k';
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        sdk => {
                            'gnarly-pets' => {
                                policy =>
                                  { hosts => [ 'localhost', 'api.other.example' ] }
                            }
                        }
                    }
                },
            }
        }
    );
    my $seen;
    my $b = bind_client(
        $st,
        sub {
            my ( $fctx, $fullurl, $fetchdef ) = @_;
            $seen = $fetchdef;
            return ( okres(), undef );
        }
    );

    # On-list host: allowed, and the senddef carries the manual-redirect
    # flag (8.2 - a 3xx must ride back rather than pull a credentialed
    # follow-up; the generated perl transport honours this slot).
    my ( undef, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx}, 'http://localhost:8903/x', { method => 'GET', headers => {} }
    );
    is( $err, undef, 'on-list allowed' );
    is( $seen->{redirect}, 'manual', 'manual redirects under a hosts policy' );

    # Off-list host: denied at the seam, transport never called.
    $seen = undef;
    ( undef, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx}, 'http://evil.example/x', { method => 'GET', headers => {} }
    );
    is( $seen, undef, 'transport not called' );
    is( $err->code, 'station_host_allow', 'denied' );
    my $errs = events_of( $st, 'error' );
    is( $errs->[-1]{err}{code}, 'station_host_allow', 'error event code' );
};

subtest 'require proxy fails on the operation path' => sub {
    reset_env();
    local $ENV{GNARLY_PETS_APIKEY} = 'k';
    my $st = Voxgig::Station->new( { config => undef, proxy => 'require' } );

    # Construction succeeds (non-blocking open, design station.md 2.1)...
    my $b = bind_client( $st, sub { return ( okres(), undef ) } );

    # ...and every operation fails closed.
    my ( undef, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx}, 'http://localhost:8903/x', { method => 'GET', headers => {} }
    );
    is( $err->code, 'station_no_proxy', 'fail closed on op' );
};

subtest 'missing secret is no_value on the op path' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );
    my $b = bind_client( $st, sub { return ( okres(), undef ) } );

    my ( undef, $err ) = $b->{utility}{fetcher}->(
        $b->{ctx},
        'http://localhost:8903/x',
        { method => 'GET', headers => { authorization => $PLACEHOLDER } }
    );
    is( $err->code, 'station_secret_no_value', 'no_value code' );
    ok( 0 <= index( "$err", 'station_secret_no_value' ), 'code in message' );
    my $errs = events_of( $st, 'error' );
    is( scalar @$errs, 1, 'one error event' );
    is( $errs->[0]{err}{code}, 'station_secret_no_value', 'event code' );
};

subtest 'secret option overrides the default name' => sub {
    reset_env();
    local $ENV{CUSTOM_TOKEN} = 'custom-9';
    my $st      = Voxgig::Station->new( { config => undef } );
    my $client  = { mode => 'live', features => [], options => undef };
    my $seen;
    my $utility = {
        fetcher => sub {
            my ( $fctx, $fullurl, $fetchdef ) = @_;
            $seen = $fetchdef->{headers}{authorization};
            return ( okres(), undef );
        }
    };
    my $options = {
        apikey  => '',
        base    => 'http://localhost:8903',
        feature => { station => { active => 1, secret => 'custom.token' } },
    };
    $client->{options} = $options;
    my $ctx = {
        client  => $client,
        utility => $utility,
        options => $options,
        config  => {%$CONFIG},
    };
    my $feature = adapter_feature( $st, {} );
    push @{ $client->{features} }, $feature;
    $feature->init( $ctx, { %{ $options->{feature}{station} } } );

    my ( undef, $err ) = $utility->{fetcher}->(
        $ctx,
        'http://localhost:8903/x',
        { method => 'GET', headers => { authorization => $PLACEHOLDER } }
    );
    is( $err, undef, 'resolved' );
    is( $seen, 'custom-9', 'override name used' );
};

# --- events (design station.md 6) ---

subtest 'ring overflow drops oldest and counts' => sub {
    my $buffer = Voxgig::Station::EventBuffer->new(3);
    $buffer->emit( { t => $_, kind => 'station' } ) for 0 .. 4;
    is_deeply( [ map { $_->{t} } @{ $buffer->events } ], [ 2, 3, 4 ], 'oldest dropped' );
    is_deeply( $buffer->status, { buffered => 3, dropped => 2 }, 'drop count' );
};

subtest 'tap serializes and unsubscribes' => sub {
    my $buffer = Voxgig::Station::EventBuffer->new;
    my @seen;
    my $unsub   = $buffer->tap( sub { push @seen, $_[0]->{t} } );
    my $raising = $buffer->tap( sub { die 'tap failure never fails the op' } );
    $buffer->emit( { t => 1, kind => 'station' } );
    $unsub->();
    $raising->();
    $buffer->emit( { t => 2, kind => 'station' } );
    is_deeply( \@seen, [1], 'unsubscribed after first' );
};

# --- profile selection (design station.md 3.5) ---

subtest 'env profile selected unless opt wins' => sub {
    reset_env();
    {
        local $ENV{VOXGIG_STATION_PROFILE} = 'prod';
        is( select_profile(undef),   'prod',  'env profile' );
        is( select_profile('stage'), 'stage', 'opt wins' );
    }
    is( select_profile(undef), 'default', 'default' );
};

# The error catalog is built from a LIST, not a qw(), and the reason is
# a real bug this pins shut: `my @CODES = qw( ... # comment ... )` takes
# every word of every comment as a code, so is_known_code once answered
# true for "#", "Features", "(design" and "8.4,". The corpus's negative
# cases ("station_made_up", "no_such_code") could never catch that - no
# spec would think to enumerate comment fragments - so the guard belongs
# here, beside the declaration it protects.
subtest 'the error catalog admits no comment fragments' => sub {
    ok( is_known_code('station_no_proxy'),      'a real code is known' );
    ok( is_known_code('station_feature_order'), 'the last real code is known' );
    for my $junk ( '#', 'Features', '(design', '8.4,', '8.5).', 'the', 'design' ) {
        ok( !is_known_code($junk), "\"$junk\" is not a code" );
    }
};

# --- the shape, as data (design station.md 4.3) ---
#
# The shape file is the artifact every port reads, so the properties the
# design leans on are asserted HERE rather than trusted: a shape edit
# that quietly reopens a map or drops a default has no other guard.
subtest 'the shape holds its documented properties' => sub {
    my $shape = config_shape();

    my $api = $shape->{profiles}{'`$CHILD`'}{api}{'`$CHILD`'};
    my $sdk = $shape->{profiles}{'`$CHILD`'}{sdk}{'`$CHILD`'};
    is( Voxgig::Station::Descriptor::canonical_serialize($api),
        Voxgig::Station::Descriptor::canonical_serialize($sdk),
        'the two block specs are identical' );

    my @sensitive = MERGE_SENSITIVE();
    is_deeply( \@sensitive, ['active'], 'MERGE_SENSITIVE is exactly [active]' );

    my %block = BLOCK_DEFAULTS();
    ok( exists $block{$_}, "merge-sensitive `$_` has a default" ) for @sensitive;

    # Every default that is NOT a container must be merge-sensitive: a
    # container merges as empty when absent, a scalar does not.
    my %issensitive = map { $_ => 1 } @sensitive;
    for my $key ( sort keys %block ) {
        my $value = $block{$key}->();
        next if ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
        ok( $issensitive{$key}, "scalar default `$key` is merge-sensitive" );
    }

    # `$OPEN` re-opens a map where a foreign grammar must pass through,
    # and the ONLY such grammar is a feature entry's own options.
    my @open;
    my $walk;
    $walk = sub {
        my ( $node, $path ) = @_;
        if ( ref($node) eq 'ARRAY' ) {
            $walk->( $node->[$_], [ @$path, $_ ] ) for 0 .. $#$node;
            return;
        }
        return unless ref($node) eq 'HASH';
        for my $key ( sort keys %$node ) {
            push @open, join( '.', @$path ) if '`$OPEN`' eq $key;
            $walk->( $node->{$key}, [ @$path, $key ] );
        }
    };
    $walk->( $shape, [] );
    is_deeply(
        [ sort @open ],
        [
            'profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`',
            'profiles.`$CHILD`.feature.`$CHILD`',
            'profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`',
        ],
        'the only open nodes are the three feature entries'
    );
};

# The normalized form is an input to VALIDATION and to nothing else, so
# the raw config every other consumer reads must come back untouched.
subtest 'normalize_config never mutates its input' => sub {
    my $raw = {
        station  => 1,
        profiles => {
            default => { sdk => { solar => { feature => { retry => {} } } } }
        },
    };
    my $before = Voxgig::Station::Descriptor::canonical_serialize($raw);
    my $out    = normalize_config($raw);

    is( Voxgig::Station::Descriptor::canonical_serialize($raw),
        $before, 'the input is unchanged' );
    ok( !exists $raw->{profiles}{default}{api}, 'no container synthesized in place' );
    ok( exists $out->{profiles}{default}{api},  'the copy has the container' );
    ok( $out->{profiles}{default}{sdk}{solar}{active}, 'the copy has `active`' );
    ok(
        $out->{profiles}{default}{sdk}{solar}{feature}{retry}{active},
        'a named feature defaults active'
    );
    is( normalize_config('nope'), 'nope', 'a non-map passes through' );
};

# --- the factory table (design station.md 6.2) ---

subtest 'provide is idempotent and conflicts loudly' => sub {
    reset_env();
    my $factory = stub_factory();

    my $entry = provide( 'gnarly-pets', $factory );
    is( $entry->{api}, 'gnarly-pets', 'entry keyed by api' );
    is( $entry->{descriptor}{slug}, 'gnarly-pets',
        'the descriptor is normalized AT PROVIDE TIME' );
    # Module self-registration PLUS an explicit provide for one api is an
    # ordinary thing for an application to end up with, so the same pair
    # twice is a no-op rather than an error.
    is( refaddr( provide( 'gnarly-pets', $factory ) ),
        refaddr($entry), 'the same pair twice is a no-op' );
    is_deeply( provided(), ['gnarly-pets'], 'provided() lists the slug' );

    my $err = do {
        local $@;
        eval {
            provide( 'gnarly-pets',
                {
                    construct => $factory->{construct},
                    config    => { %{ $factory->{config} } },
                }
            );
        };
        $@;
    };
    is( $err->code, 'station_factory_conflict', 'a different pair conflicts' );

    reset_factories();
    is_deeply( provided(), [], 'reset clears the table' );
};

# --- the loader (design station.md 6.3) ---

{

    package FakeMod::SDK;
    sub new { return bless { built => 1 }, shift }
}
{

    package FakeMod;
    our $config = { main => { slug => 'fake', version => '1.0.0' } };
}
{

    package BareMod::SDK;
    sub new { return bless {}, shift }
}

subtest 'check_package admits module names and nothing else' => sub {
    is( check_package( 'x', 'Acme::Stripe' ), 'Acme::Stripe', 'a module name' );

    for my $bad ( '', './local', '/abs/path', '~/home', 'https://x/y',
        'a\\b', 'pkg/../../escape', 'pkg/./here' )
    {
        my $err = do {
            local $@;
            eval { check_package( 'x', $bad ) };
            $@;
        };
        is( $err->code, 'station_sdk_load', "refused: \"$bad\"" );
    }

    # A TRAVERSAL SEGMENT IS NOT A LEADING MARKER: `pkg/../../escape`
    # starts with neither `.` nor `/`, so a first-character check passes
    # it and the host resolves it from outside the named dependency.
    is( camelify('stripe-eu'),      'StripeEu',   'camelify splits and caps' );
    is( camelify('voxgig_solar.1'), 'VoxgigSolar1', 'runs of non-alphanumerics' );
};

subtest 'factory_from_module reads the constructor AND the config' => sub {
    my $factory = factory_from_module( 'fake', 'FakeMod' );
    isa_ok( $factory->{construct}->( {} ), 'FakeMod::SDK', 'constructed' );
    is( $factory->{config}{main}{slug}, 'fake', 'config singleton found' );

    # A module exporting a constructor but no config cannot have its
    # feature schema read before construction, which is the whole point
    # of carrying `config` (6.2).
    my $err = do {
        local $@;
        eval { factory_from_module( 'bare', 'BareMod' ) };
        $@;
    };
    is( $err->code, 'station_sdk_load', 'no config singleton is an error' );
    ok( 0 <= index( "$err", 'no `config` singleton' ), 'the message says why' );

    my $miss = do {
        local $@;
        eval { factory_from_module( 'nothing', 'FakeMod::SDK' ) };
        $@;
    };
    is( $miss->code, 'station_sdk_load', 'no constructor is an error' );
    ok( 0 <= index( "$miss", 'tried [' ), 'the message names what was tried' );
};

# --- the declarative front door (design station.md 6) ---

sub declared_station {
    my ($sdkblocks) = @_;
    reset_env();
    provide( 'gnarly-pets', stub_factory() );
    return Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => { default => { sdk => $sdkblocks } },
            }
        }
    );
}

subtest 'sdk() caches and create() does not' => sub {
    my $st = declared_station( { 'gnarly-pets' => {} } );

    my $a = $st->sdk('gnarly-pets');
    my $b = $st->sdk('gnarly-pets');
    isa_ok( $a, 'StubSDK', 'constructed' );
    is( refaddr($a), refaddr($b), 'sdk() caches by name' );

    # The carried adapter rode `extend`, so the client is REGISTERED and
    # wrapped even though StubSDK declares no station feature of its own.
    is( scalar @{ $st->plugins }, 1, 'registered' );
    is( $st->plugins->[0]{name}, 'gnarly-pets', 'registered under the instance' );
    is( $a->{options}{apikey}, $PLACEHOLDER, 'placeholder planted' );

    my $c = $st->create('gnarly-pets');
    isnt( refaddr($c), refaddr($a), 'create() is uncached' );
    is( scalar @{ $st->plugins }, 2, 'and registers a second instance' );
    is( $st->plugins->[1]{name}, 'gnarly-pets$1', 'under an auto-assigned tag' );
    is( $st->plugins->[1]{api}, 'gnarly-pets', 'grouped by api' );
    is( $c->{options}{apikey}, '[station:gnarly-pets$1]',
        'two live instances have distinct placeholders' );
};

subtest 'the composed feature order reaches the constructor' => sub {
    reset_env();
    provide( 'gnarly-pets', stub_factory() );
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        sdk => {
                            'gnarly-pets' => {
                                feature => { test => {}, retry => { retries => 2 } }
                            }
                        }
                    }
                },
            }
        }
    );

    # `test` substitutes the base transport so it takes the innermost
    # band; everything else is band 0, outside it. A perl hash would
    # answer differently on every run, so the composed map is an ORDERED
    # map all the way to the constructor.
    is_deeply( $st->features_of('gnarly-pets')->{ordered},
        [ 'retry', 'station', 'test' ], 'station is pinned outside the base' );

    my $sdk = $st->sdk('gnarly-pets');
    is_deeply(
        [ grep { 'station' ne $_ } mapkeys( $sdk->{options}{feature} ) ],
        [ 'retry', 'test' ],
        'the constructor got them outermost first'
    );

    # ...and 6.1's inverted binding takes the instance name as an
    # OPTIONAL LEADING argument, so every existing options({...}) call is
    # unchanged.
    my $named = $st->options( 'gnarly-pets$eu', { base => 'http://x' } );
    is( $named->{feature}{station}{instance}, 'gnarly-pets$eu', 'named form' );
    is( $named->{base}, 'http://x', 'extra still applies' );
    my $bare = $st->options( { base => 'http://y' } );
    ok( !exists $bare->{feature}{station}{instance}, 'bare form is unchanged' );
    is( $bare->{base}, 'http://y', 'and still carries the extra' );
};

subtest 'a declared tag reserves an auto tag' => sub {
    my $st = declared_station(
        { 'gnarly-pets' => {}, 'gnarly-pets$1' => {} } );

    # THE REGISTRY ALONE IS NOT ENOUGH: `gnarly-pets$1` is declared and
    # not yet built, so a registry-only check would hand its identity to
    # the auto-tagged client and leave instances() reporting it live with
    # the wrong client.
    is( $st->autotag('gnarly-pets'), 'gnarly-pets$2', 'declaration reserves' );
};

subtest 'build refuses an unknown or barred instance' => sub {
    my $st = declared_station(
        { 'gnarly-pets' => {}, 'gnarly-pets$off' => { active => JSON::PP::false } }
    );

    my $unknown = do {
        local $@;
        eval { $st->sdk('gnarly-pets$nope') };
        $@;
    };
    is( $unknown->code, 'station_no_instance', 'unknown instance' );
    ok( 0 <= index( "$unknown", 'declared: [' ), 'the message lists what is declared' );

    my $barred = do {
        local $@;
        eval { $st->sdk('gnarly-pets$off') };
        $@;
    };
    is( $barred->code, 'station_instance_inactive', 'active: false bars running' );

    my $rows = $st->instances;
    is( scalar @$rows, 2, 'both stay visible in instances()' );
    is( $rows->[0]{name},   'gnarly-pets',     'sorted by name' );
    is( $rows->[1]{active}, 0,                 'the barred one is inactive' );
    is( $rows->[0]{live},   0,                 'declared is not live' );
};

subtest 'no factory names only the remedies this port offers' => sub {
    reset_env();
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => { default => { sdk => { 'gnarly-pets' => {} } } },
            }
        }
    );
    my $err = do {
        local $@;
        eval { $st->sdk('gnarly-pets') };
        $@;
    };
    is( $err->code, 'station_no_factory', 'no factory' );
    ok( 0 <= index( "$err", 'Voxgig::Station->provide' ), 'names provide' );
    ok( 0 <= index( "$err", 'api.gnarly-pets.package' ), 'names the loader key' );
};

# THE ALIAS IS RECORDED, NOT THE FIELDS. Carrying the declared `secret`
# through the feature options and stopping there leaves `policy`, `base`
# and everything else behind, so an auto-tagged client silently loses its
# declared instance's hosts allowlist and falls back to the wider
# api-level one.
subtest 'an auto tag stands for its declared instance' => sub {
    my $st = declared_station(
        {
            'gnarly-pets$eu' => {
                base   => 'http://eu:9',
                policy => { hosts => ['eu.example'] },
            }
        }
    );

    $st->create('gnarly-pets$eu');
    is( $st->declared_ref('gnarly-pets$1'), 'gnarly-pets$eu', 'alias recorded' );
    is_deeply( $st->block_for('gnarly-pets$1')->{policy}{hosts},
        ['eu.example'], 'the declared policy still governs the tag' );

    # ...and so does the declared instance's secret NAME, so every
    # per-request client of one instance shares one broker cache entry.
    is( $st->plugins->[0]{secretname}, 'gnarly_pets_eu.apikey',
        'the secret name follows the declared ref, not the tag' );
};

subtest 'features_of merges, provenances and composes the budget' => sub {
    reset_env();
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        feature => { retry => { retries => 2 } },
                        sdk     => {
                            'gnarly-pets' => {
                                feature => { retry => { wait => 5 } },
                                policy  => { budget => { rps => 7, concurrency => 3 } },
                            }
                        },
                    }
                },
            }
        }
    );

    my $of = $st->features_of('gnarly-pets');
    is( $of->{merged}{retry}{retries}, 2, 'profile level survives' );
    is( $of->{merged}{retry}{wait},    5, 'block level merges per key' );
    is( $of->{from}{retry}{retries}, 'default.feature', 'provenance: profile' );
    is( $of->{from}{retry}{wait},    'default.sdk',     'provenance: block' );

    # The budget is composed INTO the merged map, so build() orders it
    # with the ordinary rules and check() validates it against the SDK's
    # own declaration rather than it quietly doing nothing.
    ok( $of->{merged}{ratelimit}{active}, 'ratelimit switched on by policy' );
    is( $of->{merged}{ratelimit}{rate},  7, 'rps -> refill rate' );
    is( $of->{merged}{ratelimit}{burst}, 3, 'concurrency -> burst' );
    is( $of->{from}{ratelimit}{rate}, 'policy.budget', 'provenance: policy' );

    # THE IMPLICIT STATION ENTRY is for ordering only: it is never in
    # `merged`, and without it checkpin would be a permanent no-op.
    ok( !exists $of->{merged}{station}, 'station is not in the merge' );
    is( $of->{ordered}[-1], 'station', 'station is pinned innermost' );

    my $rows = $st->features( { feature => 'retry' } );
    is( scalar @$rows, 1, 'the fleet view narrows to the rows carrying it' );
    is_deeply( $rows->[0]{ordered}, ['retry'], 'and narrows each row to it' );
    is_deeply( $st->features( { feature => 'nope' } ), [],
        'a feature nothing carries is an empty answer' );
};

subtest 'check() catches a feature typo without constructing' => sub {
    reset_env();
    provide( 'gnarly-pets', stub_factory() );
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        sdk => {
                            'gnarly-pets' =>
                              { feature => { retry => { retires => 5 } } }
                        }
                    }
                },
            }
        }
    );

    my $out = $st->check;
    is_deeply( $out->{ok}, [], 'nothing passed' );
    is( scalar @{ $out->{failed} }, 1, 'one failure' );
    is( $out->{failed}[0]{code}, 'station_feature_option', 'the typo is the code' );
    ok( 0 <= index( $out->{failed}[0]{message}, 'declares no option "retires"' ),
        'the message names the key' );
    is( scalar @{ $st->plugins }, 0, 'and nothing was constructed' );

    # ...and the same check runs on the production path, so sdk() cannot
    # silently ignore it either.
    my $err = do {
        local $@;
        eval { $st->sdk('gnarly-pets') };
        $@;
    };
    is( $err->code, 'station_feature_option', 'sdk() fails the same way' );
};

subtest 'warm resolves by secret name and misses what is undeclared' => sub {
    reset_env();
    local $ENV{SHARED_APIKEY} = 'shared-value';
    provide( 'gnarly-pets', stub_factory() );
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        api => { 'gnarly-pets' => { secret => 'shared.apikey' } },
                        sdk => { 'gnarly-pets' => {}, 'gnarly-pets$eu' => {} },
                    }
                },
            }
        }
    );

    my $out = $st->warm;
    is_deeply( $out->{warmed}, [ 'gnarly-pets', 'gnarly-pets$eu' ],
        'both warmed off one shared name' );
    is_deeply( $out->{missed}, [], 'nothing missed' );

    # A NAME NOBODY DECLARED OR REGISTERED IS A MISS, NOT A LOOKUP - a
    # wider fallback would let a typo derive a secret name, call the
    # provider, and report a nonexistent instance warmed off a shared
    # api-level credential.
    my $typo = $st->warm( ['gnarly-pets$prodd'] );
    is_deeply( $typo->{warmed}, [], 'the typo warmed nothing' );
    is_deeply( $typo->{missed}, ['gnarly-pets$prodd'], 'it is a miss' );
};

subtest 'the broker caches by secret name, not by instance' => sub {
    reset_env();
    my $st = Voxgig::Station->new( { config => undef } );
    {
        local $ENV{SHARED_APIKEY} = 'once';
        is( $st->{broker}->value( 'a', 'shared.apikey' ), 'once', 'resolved' );
    }

    # The env var is gone; a cache keyed by INSTANCE would go back to the
    # store for `b` and fail. At 26 instances over 20 apis that is one
    # store round-trip turned into 26.
    is( $st->{broker}->value( 'b', 'shared.apikey' ), 'once',
        'a second instance of one name is a cache hit' );
};

subtest 'policy allowlists reach the SDK own options' => sub {
    reset_env();
    my $st = Voxgig::Station->new(
        {
            config => {
                station  => 1,
                profiles => {
                    default => {
                        sdk => {
                            'gnarly-pets' => {
                                policy => {
                                    allow => {
                                        op     => [ 'find', 'list' ],
                                        method => ['GET'],
                                    }
                                }
                            }
                        }
                    }
                },
            }
        }
    );
    my $b = bind_client( $st, sub { return ( okres(), undef ) } );

    # Unlike `base`, which is a DEFAULT the caller may override, an
    # allowlist is ENFORCEMENT: policy wins on exactly the keys it sets.
    is( $b->{options}{allow}{op},     'find,list', 'op allowlist applied' );
    is( $b->{options}{allow}{method}, 'GET',       'method allowlist applied' );
};

subtest 'the descriptor carries a feature option schema and role' => sub {
    my ($descriptor) = Voxgig::Station::Descriptor::normalize_descriptor(
        {
            main    => { slug => 'x', version => '1.0.0', target => 'perl' },
            feature => {
                plain => {},
                retry => {
                    options   => { retries => 1 },
                    transport => 'wrap',
                },
            },
        },
        undef
    );

    my %byname = map { $_->{name} => $_ } @{ $descriptor->{features} };
    ok( !exists $byname{plain}{options}, 'absent stays absent' );
    is_deeply( $byname{retry}{options}, { retries => 1 }, 'options carried' );
    is( $byname{retry}{transport}, 'wrap', 'transport carried' );

    # 8.5 then validates against exactly that, so an option the SDK does
    # not declare is a fault rather than a setting that does nothing.
    my $faults = checkfeatures( { retry => { retries => 'many' } }, $descriptor );
    is( scalar @$faults, 1, 'one fault' );
    is( $faults->[0]{code}, 'station_feature_option', 'kind mismatch' );
    ok( 0 <= index( $faults->[0]{message}, 'expects number, but found string' ),
        'the message names both kinds' );

    is_deeply( [ RESERVED_KEYS() ], [ 'active', 'order' ],
        'reserved keys are never options' );
};

done_testing();
