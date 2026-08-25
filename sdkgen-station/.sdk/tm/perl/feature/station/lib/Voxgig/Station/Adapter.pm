package Voxgig::Station::Adapter;

# The station side of the plugin contract (design station.md 3), in ONE
# place: feature_binding() is what both entry paths delegate to -
#  - the GENERATED station feature (sdkgen-station's perl template) calls
#    it from its init() and forwards its hook methods;
#  - the library's carried adapter (adapter_feature, the adopt/connect
#    retrofit for SDKs generated without the feature) is a thin shell over
#    the same call.
# Registration at init, wrap position verified, transport wrapped with
# copy-on-inject, hooks bridged to op events. Anything changed here
# changes both paths - which is the point.
#
# A port of typescript/src/adapter.ts, which is canonical.

use strict;
use warnings;

use Hash::Util::FieldHash ();
use Scalar::Util qw(blessed);
use Time::HiRes ();

use Voxgig::Station::Error ();

use Exporter 'import';
our @EXPORT_OK = qw(adapter_feature feature_binding result_outcome);

my $CORR_SEQ = 0;

# The station wrap marker (ts's __station__ property). Perl coderefs
# carry no properties and blessing one would break the SDK's
# ref($x) eq 'CODE' checks, so the mark lives in a fieldhash - keys are
# garbage-collected with the coderefs, so addresses are never stale.
Hash::Util::FieldHash::fieldhash( my %WRAP_MARK );

sub _is_station_wrap {
    my ($fn) = @_;
    return ( ref($fn) eq 'CODE' && $WRAP_MARK{$fn} ) ? 1 : 0;
}

# The hook bridge handed back to the feature (design station.md 3 item
# 3): operation semantics correlated with the HTTP events via a
# per-operation id stashed on the SDK's own ctx (the 'station$' slot on
# the blessed context hash).
{

    package Voxgig::Station::FeatureBinding;

    sub new {
        my ( $class, $station, $name ) = @_;
        return bless { station => $station, slug => $name }, $class;
    }

    # The INSTANCE name. The accessor keeps its spelling so the generated
    # adapter contract is unchanged; for a single-instance project it IS
    # the api slug, exactly as before (design station.md 7.1).
    sub slug { return $_[0]->{slug} }

    sub PrePoint {
        my ( $self, $ctx ) = @_;
        $ctx->{'station$'} = {
            corr  => 'c' . ( ++$CORR_SEQ ),
            start => int( Time::HiRes::time() * 1000 ),
        };
        return;
    }

    sub PreDone {
        my ( $self, $ctx ) = @_;
        $self->{station}->_op_event( $self->{slug}, $ctx,
            Voxgig::Station::Adapter::result_outcome($ctx) );
        return;
    }

    sub PreUnexpected {
        my ( $self, $ctx ) = @_;
        $self->{station}->_op_event( $self->{slug}, $ctx, 'unexpected' );
        return;
    }
}

# Resolve the station a binding names: a live handle, a coderef closure
# (how connect/adopt/options ride the handle through the generated
# make_options, whose deep clone would flatten a blessed object), or
# undef.
sub _resolve_station {
    my ($handle) = @_;
    return $handle if blessed($handle) && $handle->isa('Voxgig::Station');
    if ( ref($handle) eq 'CODE' ) {
        my $station = eval { $handle->() };
        return $station
          if blessed($station) && $station->isa('Voxgig::Station');
    }
    return undef;
}

# Resolve the station this activation binds to: an explicit handle in the
# feature options (connect/adopt and st->options pass one), else the
# ambient instance. No station open -> undef: an activated feature with
# no opened station is an inert no-op that emits nothing and fails
# nothing (design station.md 3.1).
sub feature_binding {
    my ( $ctx, $fopts ) = @_;
    $fopts = {} unless ref($fopts) eq 'HASH';

    my $station = _resolve_station( $fopts->{station} );
    $station = Voxgig::Station->current unless defined $station;
    return undef unless defined $station;

    my $client = $ctx->{client};

    # Same construction, second arrival (generated feature + carried
    # adapter both active on one client): the first bind won, this one is
    # inert. See Voxgig::Station::_bound_entry.
    return undef if defined $station->_bound_entry($client);

    my $utility    = $ctx->{utility};
    my $options    = $ctx->{options};
    my $calleropts = $fopts->{calleropts};

    # Position guard (design station.md 3.3): the wrap must sit
    # immediately outside the base transport - inside retry/cache/
    # ratelimit - or its http events stop being wire truth. Position in
    # the client's features list IS init order, so verify it and fail
    # loudly.
    #
    # One perl-specific tolerance (the rb port's, for the same reason):
    # the generated feature factory FALLS BACK to an inert base feature
    # for unknown names, so an activated station entry on a pre-station
    # SDK appends a stray named "base" (the ts constructor skips such
    # names instead). A base feature has a no-op init - it can never wrap
    # or record the transport - so strays are excluded from the order
    # check, which keeps the guard's actual meaning: nothing that could
    # wrap sits between the base transport and station.
    my @names;
    for my $f ( @{ ref( $client->{features} ) eq 'ARRAY' ? $client->{features} : [] } ) {
        my $name;
        if ( blessed($f) && $f->can('get_name') ) {
            $name = $f->get_name;
        }
        elsif ( ref($f) && exists $f->{name} ) {
            $name = $f->{name};
        }
        push @names, defined $name && !ref $name ? $name : '';
    }
    my @order = grep { 'base' ne $_ } @names;
    my ($self_at) = grep { 'station' eq $order[$_] } 0 .. $#order;
    my ($test_at) = grep { 'test' eq $order[$_] } 0 .. $#order;
    my $expected = defined $test_at ? $test_at + 1 : 0;
    if ( !defined $self_at || $self_at != $expected ) {
        Voxgig::Station::Error::fail( 'station_wrap_order',
            'station must init immediately after the base transport; '
              . 'feature order is [' . join( ', ', @names ) . ']' );
    }

    # Registration is driven by station now: `fopts->{instance}` is where
    # station puts the instance name it knew before construction began,
    # and _register falls back to the descriptor slug, which is today's
    # behaviour for a bare connect(SDK).
    my ( $binding, $profile_plugin ) =
      $station->_register( $client, $ctx->{config}, $options, $calleropts, $fopts );

    # The INSTANCE name, not the api slug. Everything below keys on it -
    # the placeholder, the transport wrap, the op events - because two
    # live instances of one api must be distinguishable at each
    # (design station.md 7.1, 7.3).
    my $name = $binding->{plugin};

    # Base URL precedence (design station.md 3.5): caller opts (7) beat
    # the profile (4), which beats the SDK's config default (1) already
    # in the options base. calleropts is knowable on every binding form
    # (connect/adopt and st->options both pass it).
    if (   ref($calleropts) eq 'HASH'
        && !defined $calleropts->{base}
        && ref($profile_plugin) eq 'HASH'
        && defined $profile_plugin->{base} ) {
        $options->{base} = $profile_plugin->{base};
    }

    # Policy allowlists (design station.md 16): `allow.op` / `allow.method`
    # are the same vocabulary the SDKs already enforce through their own
    # `options.allow`, so station sets those SDK options FROM POLICY and
    # enforcement stays in the SDK's own pipeline. The SDK's option form
    # is a comma-separated string, so the policy's list joins into it.
    # Applied at binding time, on BOTH entry paths, because connect/adopt
    # and the declarative build both delegate here. Unlike `base` above,
    # which is a DEFAULT the caller may override, an allowlist is
    # ENFORCEMENT: policy wins on exactly the keys it sets.
    my $ppolicy =
      ref($profile_plugin) eq 'HASH' && ref( $profile_plugin->{policy} ) eq 'HASH'
      ? $profile_plugin->{policy}
      : undef;
    my $pallow = defined $ppolicy ? $ppolicy->{allow} : undef;
    if ( ref($pallow) eq 'HASH' ) {
        my $allow =
          { %{ ref( $options->{allow} ) eq 'HASH' ? $options->{allow} : {} } };
        $allow->{op} = join( ',', @{ $pallow->{op} } )
          if ref( $pallow->{op} ) eq 'ARRAY';
        $allow->{method} = join( ',', @{ $pallow->{method} } )
          if ref( $pallow->{method} ) eq 'ARRAY';
        $options->{allow} = $allow;
    }

    if ( 'none' ne $binding->{rung} ) {
        my $placeholder = $binding->{placeholder};

        # A real credential already resident in the options is hoisted
        # into the broker and replaced by the placeholder before
        # construction completes (design station.md 3.1 adopt) -
        # options_map and prepare output become placeholder-safe from
        # here on.
        my $resident = $options->{apikey};
        if (   defined $resident
            && !ref $resident
            && '' ne $resident
            && $placeholder ne $resident ) {
            $station->_hoist( $name, $resident );
        }
        $options->{apikey} = $placeholder;
    }

    # Wrap the transport. Copy-on-inject (design station.md 5.3) happens
    # inside Voxgig::Station::_transport; auth-inactive plugins skip
    # credential planning but the wrap still observes.
    my $inner = $utility->{fetcher};
    if ( _is_station_wrap($inner) ) {
        Voxgig::Station::Error::fail( 'station_bound_twice',
            'plugin "' . $name . '" already carries a station wrap' );
    }
    my $wrapped = sub {
        my ( $fctx, $fullurl, $fetchdef ) = @_;
        return $station->_transport( $name, $inner, $fctx, $fullurl, $fetchdef );
    };
    $WRAP_MARK{$wrapped} = 1;
    $utility->{fetcher} = $wrapped;

    return Voxgig::Station::FeatureBinding->new( $station, $name );
}

# The carried adapter: the retrofit path for SDKs generated without the
# station feature (design station.md 3.1 adopt). A duck-typed feature
# whose init/hooks delegate to feature_binding - it exists so
# connect/adopt work on any regenerated SDK, and it must stay
# behaviorally identical to the generated feature template in
# sdkgen-station. The station handle rides on the adapter object itself
# (never through the options, whose deep clone would flatten it).
{

    package Voxgig::Station::AdapterFeature;

    sub new {
        my ( $class, $station, $calleropts ) = @_;
        return bless {
            version    => '0.0.1',
            name       => 'station',
            active     => 1,
            station    => $station,
            calleropts => $calleropts,
            _binding   => undef,

            # feature_add reads _options for positioning: immediately
            # after the test feature's base transport (design station.md
            # 3.3). When test is absent from the add order this is a
            # no-op append, which for a bare SDK still lands the wrap
            # immediately outside the base transport.
            _options => { '__after__' => 'test' },
        }, $class;
    }

    sub get_version { return $_[0]->{version} }
    sub get_name    { return $_[0]->{name} }
    sub get_active  { return $_[0]->{active} }

    sub init {
        my ( $self, $ctx, $fopts ) = @_;
        $fopts = {} unless ref($fopts) eq 'HASH';
        $self->{_binding} = Voxgig::Station::Adapter::feature_binding(
            $ctx,
            {
                %$fopts,
                station    => $self->{station},
                calleropts => $self->{calleropts},
            }
        );
        return;
    }

    sub PrePoint {
        my ( $self, $ctx ) = @_;
        $self->{_binding}->PrePoint($ctx) if $self->{_binding};
        return;
    }

    sub PreDone {
        my ( $self, $ctx ) = @_;
        $self->{_binding}->PreDone($ctx) if $self->{_binding};
        return;
    }

    sub PreUnexpected {
        my ( $self, $ctx ) = @_;
        $self->{_binding}->PreUnexpected($ctx) if $self->{_binding};
        return;
    }
}

sub adapter_feature {
    my ( $station, $calleropts ) = @_;
    return Voxgig::Station::AdapterFeature->new( $station, $calleropts );
}

sub result_outcome {
    my ($ctx) = @_;
    my $result = ref($ctx) ? $ctx->{result} : undef;
    return 'unknown' if !defined $result;
    return 'err'     if defined $result->{err};

    my $ok = $result->{ok};
    return 'err' if defined $ok && !( $ok ? 1 : 0 );
    return 'ok';
}

1;
