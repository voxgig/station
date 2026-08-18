package Voxgig::Station;

# voxgig/station - one control surface for outbound integrations.
#
# The station library core, solo mode (design D1): fully functional
# in-process with no other component running. The proxy (D2) is a
# deferred amplifier - `require` therefore fails on the operation path
# (design station.md 2.1/14), and `auto` degrades to solo with one
# warning event.
#
# A port of typescript/src/Station.ts, which is canonical. SDK-facing
# seams follow the generated Perl SDKs' conventions: the transport is a
# coderef returning a ($response, $err) LIST; client mode is
# $client->{mode}; per-op state rides the 'station$' slot on the SDK's
# own blessed ctx hash. One perl-specific mapping, pinned by the target
# notes: the base transport (HTTP::Tiny) converts network-level failures
# into a synthesized status-0 response with NO err, so a status-0
# response is treated as a transport failure (http event at status 0
# plus an error event) - the same observable outcome the ts library
# produces when its fetch throws.
#
# NOTE ON COPIES: this is the VENDORED copy carried by the
# sdkgen-station package (.sdk/tm/perl/feature/station/lib/Voxgig/) and
# fanned out into generated Perl SDKs, which load everything by file
# path and cannot name a CPAN distribution (none exists for Voxgig).
# The CANONICAL source lives in the voxgig/station repo at
# perl/lib/Voxgig/ - edit THERE first, then refresh this copy; the two
# must stay byte-identical apart from this paragraph's counterpart.
# In a generated project, never edit at all: add is overwrite.

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use Scalar::Util qw(blessed refaddr);
use Time::HiRes ();

our $VERSION = '0.0.1';

# Self-locating bootstrap: this lib tree may sit anywhere (a checkout, a
# vendored copy inside a generated SDK's feature container), so the lib
# root joins @INC before the sibling modules and Voxgig::Sekreto are
# loaded - `use lib` cannot express a path computed from __FILE__.
my $LIBROOT;

BEGIN {
    my $dir = File::Basename::dirname(
        File::Spec->rel2abs(__FILE__) );    # .../lib/Voxgig
    $LIBROOT = File::Basename::dirname($dir);    # .../lib
    unshift @INC, $LIBROOT unless grep { $_ eq $LIBROOT } @INC;
}

# Locate Voxgig::Sekreto (design station.md 5: the one dependency a
# station library takes). In resolution order: already loadable (the
# vendored side-by-side copy under this same lib root, an installed
# module, or a caller-supplied -I), $SEKRETO_HOME, then the sibling
# checkout a voxgig workspace keeps.
BEGIN {
    if ( !eval { require Voxgig::Sekreto; 1 } ) {
        my @candidates = grep { defined $_ } (
            (
                defined $ENV{SEKRETO_HOME}
                ? File::Spec->catdir( $ENV{SEKRETO_HOME}, 'perl', 'lib' )
                : undef
            ),
            File::Spec->catdir( $LIBROOT, '..', '..', '..', 'sekreto', 'perl', 'lib' ),
            File::Spec->catdir( $LIBROOT, '..', '..', '..', '..', 'sekreto', 'perl', 'lib' ),
            '/workspace/sekreto/perl/lib',
            '/workspace/voxgig/sekreto/perl/lib',
        );
        my $found = 0;
        for my $cand (@candidates) {
            next unless -e File::Spec->catfile( $cand, 'Voxgig', 'Sekreto.pm' );
            unshift @INC, $cand;
            $found = eval { require Voxgig::Sekreto; 1 };
            last if $found;
        }
        die 'Voxgig::Station: Voxgig::Sekreto not found - vendor it beside '
          . 'this library, install it, or set SEKRETO_HOME'
          unless $found;
    }
}

use Voxgig::Station::Error ();
use Voxgig::Station::Events ();
use Voxgig::Station::Descriptor qw(canonical_serialize normalize_descriptor);
use Voxgig::Station::Profile qw(load_config resolve_profile select_profile);
use Voxgig::Station::Secrets qw(placeholder_for);
use Voxgig::Station::Adapter ();

my $AMBIENT;
my $AMBIENT_OPTS;

# --- ambient instance (design station.md 10.2) ---

# open() is the idempotent process-wide singleton; a second open() with
# conflicting options is an error; Voxgig::Station->new($opts) stays
# isolated for tests and multi-tenant hosts. open() is non-blocking -
# solo involves no network, and the deferred proxy probe must never
# change that.
sub open {
    my ( $class, $opts ) = @_;
    my $key = _opts_key($opts);
    if ( defined $AMBIENT ) {
        if ( $key ne $AMBIENT_OPTS ) {
            Voxgig::Station::Error::fail( 'station_open_conflict',
                'Station.open() was already called with different options' );
        }
        return $AMBIENT;
    }
    $AMBIENT      = $class->new($opts);
    $AMBIENT_OPTS = $key;
    return $AMBIENT;
}

# The ambient instance, or undef - never creates one. The generated
# station feature binds through this when no explicit handle rides its
# options (design station.md 3.1: binding is never implicit; only open()
# creates the ambient instance).
sub current {
    return $AMBIENT;
}

# Test seam: drop the ambient instance.
sub reset {
    $AMBIENT      = undef;
    $AMBIENT_OPTS = undef;
    return;
}

sub _reset_if {
    my ( $class, $station ) = @_;
    if ( defined $AMBIENT && refaddr($AMBIENT) == refaddr($station) ) {
        $AMBIENT      = undef;
        $AMBIENT_OPTS = undef;
    }
    return;
}

sub _opts_key {
    my ($opts) = @_;
    my $key = eval { canonical_serialize( defined $opts ? $opts : {} ) };
    return defined $key ? $key : '';
}

sub new {
    my ( $class, $opts ) = @_;
    $opts = {} unless ref($opts) eq 'HASH';

    my $config =
      exists $opts->{config} ? $opts->{config} : load_config( $opts->{folder} );

    my $self = bless {
        opts    => $opts,
        profile => resolve_profile( $config, select_profile( $opts->{profile} ) ),
        buffer  => Voxgig::Station::EventBuffer->new(),
        registry => {},
        order    => [],
        secret_override => {},
        closed   => 0,
    }, $class;

    $self->{broker} =
      Voxgig::Station::SecretBroker->new( $self->{profile}{providers} );

    my $proxy = defined $opts->{proxy} ? $opts->{proxy} : 'auto';
    $self->{require_proxy} = ( 'require' eq $proxy ) ? 1 : 0;

    if ( 'auto' eq $proxy ) {

        # The probe is deferred with the proxy itself; absence degrades
        # to solo with a single warning event naming the cause (14).
        $self->_emit(
            {
                t    => _now_ms(),
                kind => 'station',
                meta => { warn => 'proxy absent (not found); running solo' },
            }
        );
    }

    return $self;
}

# --- binding forms (design station.md 3.1) ---

# connect(SDK, opts): station constructs the SDK itself, activating the
# adapter with 3.3 ordering (the generated make_options hoists a map-form
# station entry to just after test).
sub connect {
    my ( $self, $sdk_class, $opts ) = @_;
    return $self->_construct( $sdk_class, $opts );
}

# adopt(SDK, opts): the retrofit path - construction-time sugar, not
# post-hoc attachment (3.1). In perl it is the same construction as
# connect; a resident options apikey is hoisted by the adapter.
sub adopt {
    my ( $self, $sdk_class, $opts ) = @_;
    return $self->_construct( $sdk_class, $opts );
}

sub _construct {
    my ( $self, $sdk_class, $opts ) = @_;

    if ( $self->{closed} ) {
        Voxgig::Station::Error::fail( 'station_no_plugin', 'station is closed' );
    }

    $opts = {} unless ref($opts) eq 'HASH';
    my $options = { %$opts };
    $options->{feature} = $self->_activation( $options->{feature}, $opts );

    # The carried adapter rides extend for SDKs generated WITHOUT the
    # station feature; when the generated class exists the constructor
    # uses it and the extend copy's bind is made inert by _bound_entry
    # (both delegate to feature_binding, so behavior is identical).
    my $extend = ref( $opts->{extend} ) eq 'ARRAY' ? $opts->{extend} : [];
    $options->{extend} =
      [ @$extend, Voxgig::Station::Adapter::adapter_feature( $self, $opts ) ];

    return $sdk_class->new($options);
}

# Inverted binding (design station.md 3.1): build the plain options map a
# generated constructor already accepts - the handle and the activation
# entry; the profile's per-plugin base is applied by the adapter at init
# (caller opts still win).
sub options {
    my ( $self, $extra ) = @_;
    $extra = {} unless ref($extra) eq 'HASH';
    return { %$extra, feature => $self->_activation( $extra->{feature}, $extra ) };
}

# The activation entry. The station handle rides the options as a CODEREF
# closure: the generated make_options deep-clones its options, and a
# blessed hash object would be flattened to a plain map on the way
# through - a coderef passes by reference, so the handle survives.
sub _activation {
    my ( $self, $fmap, $calleropts ) = @_;
    $fmap = { %{ ref($fmap) eq 'HASH' ? $fmap : {} } };
    my $station = $self;
    $fmap->{station} = {
        %{ ref( $fmap->{station} ) eq 'HASH' ? $fmap->{station} : {} },
        active     => 1,
        station    => sub { return $station },
        calleropts => $calleropts,
    };
    return $fmap;
}

# --- registration (design station.md 3 item 1, called by the adapter) ---

# The registry entry whose client IS this object, or undef. Used by
# feature_binding for idempotency: connect/adopt activate the station
# entry AND ride the carried adapter on extend, so on an SDK whose
# generated features carry a real station feature class the same
# construction reaches feature_binding twice - the second arrival must
# no-op, while a genuinely second client of the same SDK class still
# fails _register's slug check (10.2).
sub _bound_entry {
    my ( $self, $client ) = @_;
    return undef unless defined $client && ref $client;
    for my $slug ( @{ $self->{order} } ) {
        my $entry = $self->{registry}{$slug};
        return $entry
          if defined $entry->{client}
          && refaddr( $entry->{client} ) == refaddr($client);
    }
    return undef;
}

sub _register {
    my ( $self, $client, $config, $options, $calleropts, $fopts ) = @_;

    my ( $descriptor, $warnings ) = normalize_descriptor( $config,
        ref($options) eq 'HASH' ? $options->{feature} : undef );
    my $slug = $descriptor->{slug};

    $fopts = {} unless ref($fopts) eq 'HASH';

    if ( exists $self->{registry}{$slug} ) {
        Voxgig::Station::Error::fail( 'station_bound_twice',
            'plugin "' . $slug . '" is already registered; binding one '
              . 'client twice is an error (10.2)' );
    }

    my $profile_plugin = $self->{profile}{plugin}{$slug};

    # Secret name precedence: the feature option (in-code, design
    # station.md 9 config.options.secret) beats the profile, which beats
    # the descriptor default.
    if ( defined $fopts->{secret} && !ref $fopts->{secret} && '' ne $fopts->{secret} ) {
        $self->{secret_override}{$slug} = $fopts->{secret};
    }
    my $secretname =
      _first_non_empty( $fopts->{secret},
        ref($profile_plugin) eq 'HASH' ? $profile_plugin->{secret} : undef );
    $secretname = $descriptor->{auth}{secretname} unless defined $secretname;

    my $auth_active = $descriptor->{auth}{active} ? 1 : 0;
    my $rung        = $auth_active ? 'R1' : 'none';
    my $binding     = {
        plugin      => $slug,
        placeholder => $auth_active ? placeholder_for($slug) : undef,
        secretname  => $auth_active ? $secretname : undef,
        rung        => $rung,
    };

    $self->{registry}{$slug} = {
        slug       => $slug,
        descriptor => $descriptor,
        rung       => $rung,
        client     => $client,
        warnings   => $warnings,
    };
    push @{ $self->{order} }, $slug;

    for my $warning (@$warnings) {
        $self->_emit(
            {
                t    => _now_ms(),
                kind => 'station',
                plugin => $slug,
                meta   => { warn => $warning },
            }
        );
    }
    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'construct',
            plugin => $slug,
            meta   => {
                name    => $descriptor->{name},
                version => $descriptor->{version},
                rung    => $rung,
            },
        }
    );

    return ( $binding, $profile_plugin );
}

sub _hoist {
    my ( $self, $slug, $value ) = @_;
    $self->{broker}->hoist( $slug, $value );
    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'station',
            plugin => $slug,
            meta   => {
                warn => 'a resident credential was hoisted into the broker '
                  . 'and replaced by the placeholder; prefer configuring the '
                  . 'secret name and letting sekreto resolve it',
            },
        }
    );
    return;
}

# --- the transport middleware (design station.md 3.3, 5.3) ---
#
# Called by the adapter's wrap coderef; `inner` is the transport that was
# current at init time. Returns the SDK's ($response, $err) LIST.
sub _transport {
    my ( $self, $slug, $inner, $fctx, $fullurl, $fetchdef ) = @_;

    # Fail-closed means traffic (2.1): with the proxy deferred, `require`
    # can never attach, so every operation fails here - the operation
    # path, never the constructor.
    if ( $self->{require_proxy} ) {
        my $err = $self->_op_error( $fctx, 'station_no_proxy',
            'proxy: "require" is set and no proxy is attached' );
        $self->_emit_err( $slug, $fctx, $err );
        return ( undef, $err );
    }

    my $entry       = $self->{registry}{$slug};
    my $placeholder = placeholder_for($slug);
    my $mode =
      ( ref( $fctx->{client} ) && defined $fctx->{client}{mode} )
      ? $fctx->{client}{mode}
      : '';
    my $live           = ( 'live' eq $mode ) ? 1 : 0;
    my $profile_plugin = $self->{profile}{plugin}{$slug};

    # Egress policy (design station.md 16), solo half: the hosts
    # allowlist is enforced at the seam every request crosses. When a
    # policy is present, redirects come back manual - a 3xx is a response
    # like any other, so a Location off the allowlist cannot pull an
    # automatic credentialed follow-up to an unapproved host (8.2's rule,
    # applied at the library seam; the generated Perl transport honours
    # the fetchdef redirect slot).
    my $hosts =
      ref($profile_plugin) eq 'HASH' && ref( $profile_plugin->{policy} ) eq 'HASH'
      ? $profile_plugin->{policy}{hosts}
      : undef;
    $hosts = undef unless ref($hosts) eq 'ARRAY';

    if ( defined $hosts && $live ) {
        my ( undef, $hostname, undef ) = _parse_url($fullurl);
        if ( !grep { defined $_ && $_ eq $hostname } @$hosts ) {
            my $err = $self->_op_error( $fctx, 'station_host_allow',
                'egress to "' . $hostname . '" denied by the hosts policy of '
                  . 'plugin "' . $slug . '"' );
            $self->_emit_err( $slug, $fctx, $err );
            return ( undef, $err );
        }
    }

    my $senddef = $fetchdef;
    if ( defined $hosts && $live ) {
        $senddef = { %{ ref($senddef) eq 'HASH' ? $senddef : {} }, redirect => 'manual' };
    }

    # Injection: at the last boundary, below every recording feature, and
    # never into mock transports (3.3) - in test/mock modes the
    # placeholder rides through untouched, so real credentials never
    # enter in-memory mock stores. Copy-on-inject: fetchdef headers IS
    # spec headers and ctrl.explain holds the fetchdef by reference, so
    # the fetchdef and its headers map are duplicated before the swap -
    # the object graph reachable from ctx/spec/ctrl keeps the
    # placeholder, ever (5.3).
    if ( $live && defined $entry && 'R1' eq $entry->{rung} ) {
        my $secretname = _first_non_empty(
            $self->{secret_override}{$slug},
            ref($profile_plugin) eq 'HASH' ? $profile_plugin->{secret} : undef
        );
        $secretname = $entry->{descriptor}{auth}{secretname}
          unless defined $secretname;

        my $value = eval { $self->{broker}->value( $slug, $secretname ) };
        if ( my $err = $@ ) {
            $err = $self->_op_error_from( $fctx, $err );
            $self->_emit_err( $slug, $fctx, $err );
            return ( undef, $err );
        }

        my $headers = {
            %{
                ref($senddef) eq 'HASH' && ref( $senddef->{headers} ) eq 'HASH'
                ? $senddef->{headers}
                : {}
            }
        };
        for my $h ( keys %$headers ) {
            my $v = $headers->{$h};
            next unless defined $v && !ref $v && 0 <= index( $v, $placeholder );
            $headers->{$h} = join( $value, split( /\Q$placeholder\E/, $v, -1 ) );
        }
        $senddef =
          { %{ ref($senddef) eq 'HASH' ? $senddef : {} }, headers => $headers };
    }

    my $st = ref( $fctx->{'station$'} ) eq 'HASH' ? $fctx->{'station$'} : undef;
    my $corr    = defined $st ? $st->{corr} : undef;
    my $started = _now_ms();

    my ( $res, $err ) = eval { $inner->( $fctx, $fullurl, $senddef ) };
    if ( my $died = $@ ) {
        $self->_emit_http( $slug, $corr, $fullurl, $senddef, 0, $started, 0 );
        $self->_emit_err( $slug, $fctx, $died );
        die $died;
    }

    if ( defined $err ) {
        $self->_emit_http( $slug, $corr, $fullurl, $senddef, 0, $started, 0 );
        $self->_emit_err( $slug, $fctx, $err );
        return ( $res, $err );
    }

    my $status =
      ( ref($res) eq 'HASH' && defined $res->{status} && !ref $res->{status} )
      ? int( $res->{status} )
      : 0;

    if ( 0 == $status ) {

        # The perl base transport (HTTP::Tiny) synthesizes a status-0
        # response (no err) for network-level failures; map it to the
        # same events the ts library emits when its transport throws.
        $self->_emit_http( $slug, $corr, $fullurl, $senddef, 0, $started, 0 );
        if ( ref($res) eq 'HASH' ) {
            my $message =
              defined $res->{statusText} && !ref $res->{statusText}
              ? "$res->{statusText}"
              : 'transport failure';
            $self->_emit(
                {
                    t    => _now_ms(),
                    kind => 'error',
                    plugin => $slug,
                    corr   => $corr,
                    err    => { message => $self->redact($message) },
                }
            );
        }
        return ( $res, $err );
    }

    my $bytes = 0;
    if ( ref($res) eq 'HASH' && ref( $res->{headers} ) eq 'HASH' ) {
        my $cl = $res->{headers}{'content-length'};
        $bytes = int($cl) if defined $cl && !ref $cl && $cl =~ /^\d+/;
    }
    $self->_emit_http( $slug, $corr, $fullurl, $senddef, $status, $started, $bytes );

    return ( $res, $err );
}

# Op events from the hook bridge (design station.md 3 item 3).
sub _op_event {
    my ( $self, $slug, $ctx, $outcome ) = @_;
    my $st = ref( $ctx->{'station$'} ) eq 'HASH' ? $ctx->{'station$'} : {};

    # ctx->{op} is the SDK's resolved Operation: name + entity, with '_'
    # as the generated Perl SDKs' absence sentinel.
    my $op     = ref( $ctx->{op} ) ? $ctx->{op} : {};
    my $entity = defined $op->{entity} && !ref $op->{entity} ? $op->{entity} : '';
    $entity = '' if '_' eq $entity;
    if ( '' eq $entity
        && blessed( $ctx->{entity} )
        && $ctx->{entity}->can('get_name') ) {
        $entity = $ctx->{entity}->get_name;
        $entity = '' unless defined $entity && !ref $entity;
    }
    my $opname = defined $op->{name} && !ref $op->{name} ? $op->{name} : '';
    $opname = '' if '_' eq $opname;

    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'op',
            plugin => $slug,
            corr   => $st->{corr},
            op     => {
                entity     => $entity,
                op         => $opname,
                outcome    => $outcome,
                durationMs => defined $st->{start} ? _now_ms() - $st->{start} : 0,
            },
        }
    );
    return;
}

# --- the query/observe surface (design station.md 3.2, 6) ---

sub plugins {
    my ($self) = @_;
    return [
        map {
            my $entry = $self->{registry}{$_};
            {
                slug       => $entry->{slug},
                descriptor => $entry->{descriptor},
                rung       => $entry->{rung},
                warnings   => [ @{ $entry->{warnings} } ],
            }
        } @{ $self->{order} }
    ];
}

sub descriptor_of {
    my ( $self, $slug ) = @_;
    my $entry = defined $slug ? $self->{registry}{$slug} : undef;
    if ( !defined $entry ) {
        Voxgig::Station::Error::fail( 'station_no_plugin',
            'unknown plugin "' . ( defined $slug ? $slug : '' ) . '"; known: ['
              . join( ', ', @{ $self->{order} } ) . ']' );
    }
    return $entry->{descriptor};
}

sub canonical_descriptor {
    my ( $self, $slug ) = @_;
    return canonical_serialize( $self->descriptor_of($slug) );
}

sub events {
    my ($self) = @_;
    return $self->{buffer}->events;
}

sub tap {
    my ( $self, $fn ) = @_;
    return $self->{buffer}->tap($fn);
}

sub status {
    my ($self) = @_;
    return {
        mode    => 'solo',
        profile => $self->{profile}{name},
        plugins => [
            map { { slug => $_->{slug}, rung => $_->{rung} } } @{ $self->plugins }
        ],
        events => $self->{buffer}->status,
    };
}

sub redact {
    my ( $self, $text ) = @_;
    return $self->{broker}->scrub($text);
}

sub refresh_secrets {
    my ($self) = @_;
    $self->{broker}->refresh;
    return;
}

# close: flush (solo: nothing in flight), then warn on profile plugin
# keys that matched no registered plugin - a typo'd key silently
# configuring nothing is the worst outcome for a secrets-and-policy file
# (design station.md 11).
sub close {
    my ($self) = @_;
    return if $self->{closed};

    for my $slug ( sort keys %{ $self->{profile}{plugin} } ) {
        next if exists $self->{registry}{$slug};
        $self->_emit(
            {
                t    => _now_ms(),
                kind => 'station',
                meta => {
                    warn => 'profile plugin key "' . $slug
                      . '" matched no registered plugin',
                },
            }
        );
    }
    $self->{closed} = 1;
    Voxgig::Station->_reset_if($self);
    return;
}

sub closed {
    my ($self) = @_;
    return $self->{closed} ? 1 : 0;
}

# --- internals ---

sub _emit {
    my ( $self, $ev ) = @_;
    $self->{buffer}->emit($ev);
    return;
}

sub _emit_http {
    my ( $self, $slug, $corr, $fullurl, $fetchdef, $status, $started, $bytes ) = @_;
    my ( $host, undef, $path ) = _parse_url($fullurl);
    $self->_emit(
        {
            t      => $started,
            kind   => 'http',
            plugin => $slug,
            corr   => $corr,
            http   => {
                method => (
                    ref($fetchdef) eq 'HASH' && defined $fetchdef->{method}
                    ? "$fetchdef->{method}"
                    : 'GET'
                ),
                host       => $host,
                path       => $path,
                status     => $status,
                durationMs => _now_ms() - $started,
                bytes      => $bytes,
            },
        }
    );
    return;
}

sub _emit_err {
    my ( $self, $slug, $fctx, $err ) = @_;
    my $st =
      ref($fctx) && ref( $fctx->{'station$'} ) eq 'HASH'
      ? $fctx->{'station$'}
      : undef;

    my $code;
    if ( blessed($err) && $err->can('code') ) {
        $code = $err->code;
    }
    elsif ( ref($err) eq 'HASH' ) {
        $code = $err->{code};
    }
    $code = undef unless defined $code && !ref $code && '' ne $code;

    # The scrub keeps an upstream echo of a credential out of the event
    # stream (design station.md 7 as revised: exact-value, no length
    # floor).
    my $message = $self->redact( defined $err ? "$err" : '' );
    $message =~ s/\s+\z//;

    my $ev_err = { message => $message };
    $ev_err->{code} = $code if defined $code;

    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'error',
            plugin => $slug,
            corr   => defined $st ? $st->{corr} : undef,
            err    => $ev_err,
        }
    );
    return;
}

# A station failure on the SDK's error path: prefer the ctx's own
# make_error so the SDK error carries the station code in its `code`
# slot (the generated Perl SDKs' idiom); a bare StationError - whose
# stringification carries the code too - covers duck-typed harnesses.
sub _op_error {
    my ( $self, $fctx, $code, $message ) = @_;
    if ( blessed($fctx) && $fctx->can('make_error') ) {
        return $fctx->make_error( $code, $code . ': ' . $message );
    }
    return Voxgig::Station::StationError->new( $code, $message );
}

sub _op_error_from {
    my ( $self, $fctx, $err ) = @_;
    if (   blessed($err)
        && $err->isa('Voxgig::Station::StationError')
        && blessed($fctx)
        && $fctx->can('make_error') ) {
        return $fctx->make_error( $err->code, $err->message );
    }
    return $err;
}

sub _first_non_empty {
    for my $val (@_) {
        return $val if defined $val && !ref $val && '' ne $val;
    }
    return undef;
}

# ( host-with-port, hostname, path ) from a URL, core-regex only (URI is
# not core). Mirrors ts URL semantics: host keeps a non-default port,
# hostname strips it, an empty path reads as '/'. IPv6 literals are out
# of scope for the solo library (a bracketed host parses as-is).
sub _parse_url {
    my ($fullurl) = @_;
    my $url = defined $fullurl && !ref $fullurl ? $fullurl : '';

    if ( $url =~ m{^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)} ) {
        my ( $scheme, $authority, $path ) = ( lc $1, $2, $3 );
        $authority =~ s/^[^@]*@//;    # userinfo, if any
        my ( $hostname, $port ) = $authority =~ /^(.*?)(?::(\d+))?$/;
        $hostname = '' unless defined $hostname;
        my $default =
            'http' eq $scheme  ? 80
          : 'https' eq $scheme ? 443
          :                      -1;
        my $host =
          ( defined $port && $port != $default )
          ? $hostname . ':' . $port
          : $hostname;
        $path = '/' if !defined $path || '' eq $path;
        return ( $host, $hostname, $path );
    }

    return ( '', '', $url );
}

sub _now_ms {
    return int( Time::HiRes::time() * 1000 );
}

1;
