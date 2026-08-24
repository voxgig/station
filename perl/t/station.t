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

done_testing();
