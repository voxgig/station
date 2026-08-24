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
# NOTE ON COPIES: the canonical source of this library lives in the
# voxgig/station repo at perl/lib/Voxgig/. The sdkgen-station package
# carries a VENDORED copy under .sdk/tm/perl/feature/station/lib/Voxgig/
# (generated Perl SDKs load everything by file path and no Voxgig
# distribution exists on CPAN). Edit HERE first, then refresh the
# vendored copy - the two must stay byte-identical apart from this
# paragraph's counterpart.

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use JSON::PP ();
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
use Voxgig::Station::Descriptor qw(
  canonical_serialize normalize_descriptor secretname_default
);
use Voxgig::Station::Factory qw(factory_for);
use Voxgig::Station::Feature qw(
  checkfeatures checkpin composefeatures featuresources mergefeatures
  resolveorder
);
use Voxgig::Station::Loader qw(load_sync);
use Voxgig::Station::Profile qw(
  config_scope load_config refapi resolve_profile select_profile
);
use Voxgig::Station::Secrets qw(placeholder_for);
use Voxgig::Station::Shape qw(normalize_config validate_config);
use Voxgig::Station::Struct qw(mapkeys ordered_map);
use Voxgig::Station::Adapter ();

use Exporter 'import';
our @EXPORT_OK = qw(check_instance_name check_instance_tag instance_ref);

my $AMBIENT;
my $AMBIENT_OPTS;

# --- the instance ref grammar (design station.md 6.1) ---
#
# The ref grammar is the JOINT identity model's (station-and-plugin.md 2,
# plugin design 4): a name is a package-ish specifier, a tag is not - it
# MAY start with a digit, because auto-tagging assigns integer tags, and
# admits neither `@` nor `/`; both cap at 1024; the split is on the FIRST
# `$`, so `a$b$c` is a good name with a bad tag.
#
# `\z` rather than `$`, deliberately: perl's `$` also matches before a
# final newline, so `"stripe\n"` would pass a rule every other port
# rejects - and a registry key with a newline in it is a key nothing else
# can name.
my $REF_NAME_RE = qr{^[a-zA-Z@][a-zA-Z0-9.~_\-/]*\z};
my $REF_TAG_RE  = qr{^[a-zA-Z0-9.~_-]+\z};
my $REF_MAX     = 1024;

sub check_instance_name {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return 0 if 0 == length($name) || $REF_MAX < length($name);
    return $name =~ $REF_NAME_RE ? 1 : 0;
}

sub check_instance_tag {
    my ($tag) = @_;
    return 0 unless defined $tag && !ref $tag;

    # The empty tag is an ordinary tag: the single-instance case writes
    # no tag and never learns tags exist.
    return 1 if 0 == length($tag);
    return 0 if $REF_MAX < length($tag);
    return $tag =~ $REF_TAG_RE ? 1 : 0;
}

# Validate a ref against the joint grammar and return its CANONICAL
# spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
# `stripe` are ONE registry key rather than two.
sub _checkref {
    my ($ref) = @_;
    my $cut = index( $ref, '$' );
    my $name = -1 == $cut ? $ref : substr( $ref, 0, $cut );
    my $tag  = -1 == $cut ? ''   : substr( $ref, $cut + 1 );

    if ( !check_instance_name($name) ) {
        Voxgig::Station::Error::fail( 'station_instance_api',
            'invalid instance name "' . $name . '" in ref "' . $ref
              . '": a name starts with a letter or `@` and uses '
              . '`[a-zA-Z0-9.~_-/]`, max 1024 (6.1)' );
    }
    if ( !check_instance_tag($tag) ) {
        Voxgig::Station::Error::fail( 'station_instance_api',
            'invalid instance tag "' . $tag . '" in ref "' . $ref
              . '": a tag uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)' );
    }
    return '' eq $tag ? $name : $ref;
}

sub _checkapi {
    my ( $api, $ref ) = @_;
    if ( refapi($ref) ne $api ) {
        Voxgig::Station::Error::fail( 'station_instance_api',
            'instance "' . $ref . '" names api "' . refapi($ref)
              . '", but the SDK passed is api "' . $api
              . '"; `as` is a tag, not a free name (6.1)' );
    }
    return $ref;
}

# `as` IS A TAG, NOT A FREE NAME (design station.md 6.1).
#
# The api comes from the SDK being passed, so the resulting ref is
# `<api>$<tag>` and multi-instance works imperatively too. A full ref is
# also accepted and is VALIDATED: its name must equal the SDK's api
# slug, or it is `station_instance_api`.
#
# An `as` that took an arbitrary name would reintroduce exactly the
# second-identity problem the ref re-key removed: under the ref
# invariant `as: 'solar-eu'` would denote the untagged `solar-eu`
# DEFINITION, not an instance of the SDK just handed in.
#
# A bare connect(SDK) with no name falls back to the descriptor slug,
# which is today's behaviour and why the single-instance case is
# unchanged to the byte.
sub instance_ref {
    my ( $api, $fopts ) = @_;
    $fopts = {} unless ref($fopts) eq 'HASH';
    $api = defined $api ? "$api" : '';

    my $explicit = _first_non_empty( $fopts->{instance} );
    return _checkref( _checkapi( $api, "$explicit" ) ) if defined $explicit;

    my $as = _first_non_empty( $fopts->{as} );

    # The bare fallback is the SLUG - a NAME, never a ref: a `$` in it is
    # an invalid name, not an implicit tag.
    if ( !defined $as ) {
        if ( !check_instance_name($api) ) {
            Voxgig::Station::Error::fail( 'station_instance_api',
                'invalid instance name "' . $api . '": a name starts with a '
                  . 'letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)' );
        }
        return $api;
    }

    # A `$`-LESS STRING IS ALWAYS A TAG. `as: 'stripe'` on api `stripe`
    # yields `stripe$stripe`, not `stripe`: 6.1 says twice and
    # emphatically that `as` is a tag rather than a free name, and a rule
    # with no exceptions is the one that ports the same way twenty times.
    # Collapsing when the tag happens to equal the api would make `as`
    # mean different things at different values; someone who wants the
    # untagged instance passes no `as` at all.
    $as = "$as";
    return _checkref(
        -1 == index( $as, '$' ) ? $api . '$' . $as : _checkapi( $api, $as ) );
}

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

# 6.2's second path, and the front door the docs name. Delegates to the
# same process-global table the free function fills; there is ONE
# registry, not two.
sub provide {
    my ( $class, $api, $factory ) = @_;
    Voxgig::Station::Factory::provide( $api, $factory );
    return;
}

sub new {
    my ( $class, $opts ) = @_;
    $opts = {} unless ref($opts) eq 'HASH';

    my $config =
      exists $opts->{config} ? $opts->{config} : load_config( $opts->{folder} );

    # Which side of the repo review boundary this config came from (6.3).
    # READ THE EXPLICIT OPTION FIRST, then an in-code config (the
    # application wrote it, so it is repo-scoped by construction), then
    # where the file was found. Inferring BEFORE reading the explicit
    # option is a real precedence bug: it makes `repo_scoped => 0`
    # unsettable for any caller passing a config in code, which is every
    # test of the rule.
    my $explicit_scope =
      exists $opts->{repo_scoped} ? $opts->{repo_scoped} : $opts->{repoScoped};
    my $repo_scoped =
        defined $explicit_scope ? ( $explicit_scope ? 1 : 0 )
      : exists $opts->{config}  ? 1
      : ( 'user' ne config_scope( $opts->{folder} ) ) ? 1
      :                                                 0;

    # Normalize, then validate (design station.md 4.2). A malformed
    # station.json fails open() with EVERY error at once - an
    # eighteen-instance config must not die because the eighteenth has a
    # typo'd package name.
    #
    # resolve_profile then reads the RAW config, NOT the normalized one.
    # The normalized form is an input to validation and to nothing else:
    # block defaults synthesized before the profile merge would let a
    # one-key overlay overwrite the base's `active: false` and silently
    # re-enable a barred integration (3.3, 4.2).
    validate_config( normalize_config($config) ) if defined $config;

    my $self = bless {
        opts    => $opts,

        # The RAW config, kept for 8.7's provenance: the resolved profile
        # has already collapsed the levels that provenance has to name.
        raw     => $config,
        repo_scoped => $repo_scoped,
        profile => resolve_profile( $config, select_profile( $opts->{profile} ) ),
        buffer  => Voxgig::Station::EventBuffer->new(),
        registry => {},
        order    => [],

        # 6.1: sdk(name) caches; create() deliberately does not.
        clients  => {},

        # An auto-assigned tag to the DECLARED instance it stands for
        # (5.3). Kept beside the registry rather than inside it because
        # the mapping exists before construction, and block_for needs it
        # during registration.
        alias_of => {},

        # 7.4: the shared per-api descriptor cache - see describe().
        descriptor_cache => {},
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

    # 6.1: `as` is a TAG, resolved against the api in _register - the api
    # comes from the SDK being passed and is not knowable here until that
    # SDK's config has been normalized.
    my %ident;
    $ident{as} = $opts->{as} if defined $opts->{as};
    $ident{instance} = $opts->{instance} if defined $opts->{instance};
    $options->{feature} = $self->_activation( $options->{feature}, $opts, \%ident );

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
# 6.1: `options($instance_name?, $extra?)`. The name is OPTIONAL AND
# LEADING, so every existing `options({...})` call is unchanged - the
# inverted binding is the statically typed languages' path and they need
# to say which instance they are building without a second method.
sub options {
    my ( $self, $a, $b ) = @_;
    my $named = defined $a && !ref $a;
    my $instance = $named ? $a : undef;
    my $extra = $named ? $b : $a;
    $extra = {} unless ref($extra) eq 'HASH';

    my %ident;
    $ident{instance} = $instance if defined $instance;
    return {
        %$extra,
        feature => $self->_activation( $extra->{feature}, $extra, \%ident ),
    };
}

# The activation entry. The station handle rides the options as a CODEREF
# closure: the generated make_options deep-clones its options, and a
# blessed hash object would be flattened to a plain map on the way
# through - a coderef passes by reference, so the handle survives.
# Copy a map, KEEPING INSERTION ORDER when the source has one. build()
# hands _activation the composed feature map, which is ordered because
# 8.4 resolved it; an imperative connect() hands it a plain perl hash,
# which has no order to keep - and must not have to load voxgig/struct
# just to build one it does not need.
sub _copymap {
    my ($src) = @_;
    $src = {} unless ref($src) eq 'HASH';
    return {%$src} unless defined tied(%$src);
    my $out = ordered_map();
    $out->{$_} = $src->{$_} for mapkeys($src);
    return $out;
}

sub _activation {
    my ( $self, $fmap, $calleropts, $ident ) = @_;
    $fmap = _copymap($fmap);
    my $station = $self;
    $fmap->{station} = {
        %{ ref( $fmap->{station} ) eq 'HASH' ? $fmap->{station} : {} },
        active     => 1,
        station    => sub { return $station },
        calleropts => $calleropts,
        %{ ref($ident) eq 'HASH' ? $ident : {} },
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
    for my $name ( @{ $self->{order} } ) {
        my $entry = $self->{registry}{$name};
        return $entry
          if defined $entry->{client}
          && refaddr( $entry->{client} ) == refaddr($client);
    }
    return undef;
}

# The profile block that governs an instance - its own if the profile
# declares it, otherwise its API'S.
#
# resolve_profile builds `profile.sdk` from the declared refs alone ("an
# api block declares no instance, so the ref set comes from the two
# `sdk` maps"), shallow-merging `profile.api[a]` into each. That is right
# for a declared instance and leaves an IMPERATIVE one - connect(SDK,
# {as => 'test'}), named but never written into config - with no block at
# all. The api-level `secret`, `base` and most seriously `policy.hosts`
# then did not reach it, so a profile that denies egress everywhere
# denied nothing for a tagged client.
#
# ONE RULE, ONE PLACE: registration and the transport seam both ask here,
# because them disagreeing is how the credential and the allowlist came
# apart in the first place.
sub block_for {
    my ( $self, $name ) = @_;
    my $declared = $self->{profile}{sdk}{ $self->declared_ref($name) };
    return $declared if defined $declared;
    return $self->{profile}{api}{ refapi($name) };
}

# The DECLARED instance an assigned tag stands for, or the name itself.
# create('stripe$prod') registers under `stripe$1`, and every question
# about that client's configuration - its secret, its base, its egress
# policy - is a question about `stripe$prod`.
sub declared_ref {
    my ( $self, $name ) = @_;
    my $at = $self->{alias_of}{$name};
    return defined $at ? $at : $name;
}

# 7.4: THE DESCRIPTOR IS SHARED, because it describes the api rather than
# any use of it. normalize_descriptor runs once per api and every
# instance of that api holds a reference to the same object - at 26
# instances over 20 apis that is 20 normalizations, not 26, and the
# canonical serialization the proxy dedupes registrations by is computed
# once per api too.
#
# Normalized with NO per-instance features, so the shared value holds
# only API-stable metadata - which is what the factory table already does
# at provide time. Per-instance activation is features_of(name)'s answer;
# a cache keyed by slug but built from the first instance's feature map
# would make descriptor_of() construction-order-dependent.
sub describe {
    my ( $self, $config ) = @_;

    my $slug =
      ( ref($config) eq 'HASH'
          && ref( $config->{main} ) eq 'HASH'
          && defined $config->{main}{slug}
          && !ref $config->{main}{slug} ) ? "$config->{main}{slug}" : '';

    if ( '' ne $slug ) {
        my $hit = $self->{descriptor_cache}{$slug};
        return @$hit if defined $hit;
    }

    my ( $descriptor, $warnings ) = normalize_descriptor( $config, undef );
    $self->{descriptor_cache}{ $descriptor->{slug} } = [ $descriptor, $warnings ];
    return ( $descriptor, $warnings );
}

sub _register {
    my ( $self, $client, $config, $options, $calleropts, $fopts ) = @_;

    my ( $descriptor, $warnings ) = $self->describe($config);
    my $api = $descriptor->{slug};

    $fopts = {} unless ref($fopts) eq 'HASH';

    # 7.5: station knows the instance name before construction begins and
    # passes it through the feature options. A bare connect(SDK) with no
    # name falls back to the descriptor slug, which is today's behaviour
    # and why the single-instance case is unchanged.
    my $name = instance_ref( $api, $fopts );

    # 7.1: the check moves to the INSTANCE key. Two clients of one api is
    # the NORMAL case now; two bindings of one instance is still the
    # error it was.
    if ( exists $self->{registry}{$name} ) {
        Voxgig::Station::Error::fail( 'station_bound_twice',
            'instance "' . $name . '" is already registered; binding one '
              . 'client twice is an error (10.2)' );
    }

    my $profile_plugin = $self->block_for($name);

    # Secret name precedence: the feature option (in-code, design
    # station.md 9 config.options.secret) beats the profile block, which
    # beats the INSTANCE-derived default.
    #
    # 5.1: secretname_default takes the instance name, not the api slug.
    # For an untagged instance the two are the same string, so the
    # single-instance case is unchanged to the byte. And the DEFAULT
    # takes the DECLARED ref, not the assigned tag: `stripe$1` created
    # from `stripe$test` derives `stripe_test.apikey`, so every
    # per-request client of one instance shares one broker cache entry
    # (5.3).
    #
    # The descriptor's own `auth.secretname` stays the API-level default
    # and is NOT used here (7.4): one descriptor is shared by every
    # instance of an api and cannot hold two instance-derived names.
    my $secretname =
      _first_non_empty( $fopts->{secret},
        ref($profile_plugin) eq 'HASH' ? $profile_plugin->{secret} : undef );
    $secretname = secretname_default( $self->declared_ref($name) )
      unless defined $secretname;

    my $auth_active = $descriptor->{auth}{active} ? 1 : 0;
    my $rung        = $auth_active ? 'R1' : 'none';
    my $binding     = {
        plugin => $name,
        api    => $api,

        # 7.2: two live instances of one api MUST have distinct
        # placeholders or the injection seam cannot tell which credential
        # a header wants.
        placeholder => $auth_active ? placeholder_for($name) : undef,
        secretname  => $auth_active ? $secretname : undef,
        rung        => $rung,
    };

    $self->{registry}{$name} = {
        name       => $name,
        api        => $api,
        slug       => $api,
        descriptor => $descriptor,
        rung       => $rung,
        client     => $client,
        warnings   => $warnings,

        # THE EFFECTIVE NAME, resolved once and read from here at the
        # transport seam with NO FALLBACK.
        secretname => $auth_active ? $secretname : undef,
    };
    push @{ $self->{order} }, $name;

    for my $warning (@$warnings) {
        $self->_emit(
            {
                t      => _now_ms(),
                kind   => 'station',
                plugin => $name,
                api    => $api,
                meta   => { warn => $warning },
            }
        );
    }
    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'construct',
            plugin => $name,
            api    => $api,
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
    my ( $self, $name, $value ) = @_;
    $self->{broker}->hoist( $name, $value );
    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'station',
            plugin => $name,
            api    => refapi($name),
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
    my ( $self, $name, $inner, $fctx, $fullurl, $fetchdef ) = @_;

    # Fail-closed means traffic (2.1): with the proxy deferred, `require`
    # can never attach, so every operation fails here - the operation
    # path, never the constructor.
    if ( $self->{require_proxy} ) {
        my $err = $self->_op_error( $fctx, 'station_no_proxy',
            'proxy: "require" is set and no proxy is attached' );
        $self->_emit_err( $name, $fctx, $err );
        return ( undef, $err );
    }

    my $entry       = $self->{registry}{$name};
    my $placeholder = placeholder_for($name);
    my $mode =
      ( ref( $fctx->{client} ) && defined $fctx->{client}{mode} )
      ? $fctx->{client}{mode}
      : '';
    my $live = ( 'live' eq $mode ) ? 1 : 0;

    # ONE RULE, ONE PLACE (7.5): the seam asks block_for, exactly as
    # registration did, so an imperative tagged instance gets its api's
    # policy rather than none at all.
    my $profile_plugin = $self->block_for($name);

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
                  . 'plugin "' . $name . '"' );
            $self->_emit_err( $name, $fctx, $err );
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

        # 7.4: THE EFFECTIVE NAME, resolved once at registration and
        # stored on the entry. Re-deriving it here got the precedence
        # right and the FALLBACK wrong: `descriptor.auth.secretname` is
        # the API-level default, and one descriptor is shared by every
        # instance of an api - so a tagged instance with no explicit
        # `secret` read `stripe.apikey` where registration had recorded
        # `stripe_test.apikey`. Either the request fails despite the
        # credential being configured, or it succeeds with a sibling's.
        #
        # NO FALLBACK: this branch is guarded by 'R1' eq rung, which is
        # set only when the descriptor's auth is active - the same
        # condition under which `entry->{secretname}` is populated.
        my $secretname = $entry->{secretname};

        my $value = eval { $self->{broker}->value( $name, $secretname ) };
        if ( my $err = $@ ) {
            $err = $self->_op_error_from( $fctx, $err );
            $self->_emit_err( $name, $fctx, $err );
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
        $self->_emit_http( $name, $corr, $fullurl, $senddef, 0, $started, 0 );
        $self->_emit_err( $name, $fctx, $died );
        die $died;
    }

    if ( defined $err ) {
        $self->_emit_http( $name, $corr, $fullurl, $senddef, 0, $started, 0 );
        $self->_emit_err( $name, $fctx, $err );
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
        $self->_emit_http( $name, $corr, $fullurl, $senddef, 0, $started, 0 );
        if ( ref($res) eq 'HASH' ) {
            my $message =
              defined $res->{statusText} && !ref $res->{statusText}
              ? "$res->{statusText}"
              : 'transport failure';
            $self->_emit(
                {
                    t      => _now_ms(),
                    kind   => 'error',
                    plugin => $name,
                    api    => refapi($name),
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
    $self->_emit_http( $name, $corr, $fullurl, $senddef, $status, $started, $bytes );

    return ( $res, $err );
}

# Op events from the hook bridge (design station.md 3 item 3).
sub _op_event {
    my ( $self, $name, $ctx, $outcome ) = @_;
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
            plugin => $name,
            api    => refapi($name),
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

# One entry per LIVE INSTANCE (6.1), and EXHAUSTIVE: auto-tagged entries
# are NOT collapsed here, because inspection, health reporting and
# cleanup all need to enumerate the clients create() produced, which is
# exactly when you most want them. Truncation is a presentation decision
# and belongs to status().
sub plugins {
    my ($self) = @_;
    return [
        map {
            my $entry = $self->{registry}{$_};
            {
                name       => $entry->{name},
                api        => $entry->{api},

                # Retained: it IS the api, which is what `slug` always
                # meant here, and dropping it would break every consumer
                # for no gain while the two are equal for untagged
                # instances.
                slug       => $entry->{api},
                descriptor => $entry->{descriptor},
                rung       => $entry->{rung},
                secretname => $entry->{secretname},
                warnings   => [ @{ $entry->{warnings} } ],
            }
        } @{ $self->{order} }
    ];
}

# --- the declarative front door (design station.md 6) ---

# The instance, constructed on first call and CACHED: same name -> same
# object. That caching is what makes "get it where you need it" a real
# instruction - call it in a request handler, in a worker, in a test, and
# the first call pays construction while the rest are a hash lookup.
#
# SYNCHRONOUS, which is the whole reason perl's loader is `require` and
# nothing else.
sub sdk {
    my ( $self, $name ) = @_;
    $name = defined $name ? "$name" : '';
    my $cached = $self->{clients}{$name};
    return $cached if defined $cached;

    my $client = $self->build( $name, undef );
    $self->{clients}{$name} = $client;
    return $client;
}

# An UNCACHED client from the same resolved config plus overrides, for
# the case that genuinely wants a distinct one - a per-request credential
# scope, a test double. Deliberately the longer name.
#
# It registers under an AUTO-ASSIGNED TAG, because 7.5 registers every
# constructed adapter under its instance name and station_bound_twice
# fires on a second binding of one name: a second create('stripe') would
# otherwise throw, which is exactly the per-request case this exists for.
#
# The SECRET NAME does not follow the assigned tag: it resolves from the
# DECLARED instance the tag was assigned under, so every client of one
# instance shares one broker cache entry rather than re-resolving per
# request (5.3).
sub create {
    my ( $self, $name, $overrides ) = @_;
    $name = defined $name ? "$name" : '';
    return $self->build( $name, $self->autotag($name), $overrides );
}

# The lowest positive integer tag not already taken, by a LIVE instance
# or a DECLARED one.
#
# THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`, and
# until something constructs it the registry says false - so
# create('stripe$prod') would take that identity, instances() would
# report the declared `stripe$1` as live with the wrong client, and a
# later sdk('stripe$1') would fail station_bound_twice against a binding
# that was never its own. Declaration reserves the name whether or not it
# has been built.
sub autotag {
    my ( $self, $name ) = @_;
    my $api = refapi($name);
    for ( my $n = 1 ; ; $n++ ) {
        my $ref = $api . '$' . $n;
        return $ref
          if !exists $self->{registry}{$ref}
          && !defined $self->{profile}{sdk}{$ref};
    }
}

sub build {
    my ( $self, $name, $as, $overrides ) = @_;

    if ( $self->{closed} ) {
        Voxgig::Station::Error::fail( 'station_no_plugin', 'station is closed' );
    }

    my $block = $self->{profile}{sdk}{$name};
    if ( !defined $block ) {
        Voxgig::Station::Error::fail( 'station_no_instance',
            'no declared instance "' . $name . '"; declared: ['
              . join( ', ', sort keys %{ $self->{profile}{sdk} } ) . ']' );
    }
    if ( _isfalse( $block->{active} ) ) {
        Voxgig::Station::Error::fail( 'station_instance_inactive',
            'instance "' . $name . '" is declared with `active: false`, which '
              . 'bars it from running while keeping it visible in instances()' );
    }

    my $api   = refapi($name);
    my $entry = $self->resolve_factory( $api, $block );

    # 8.5 VALIDATES HERE, not only in check(). The schema arrives with
    # the factory, so the moment a factory is resolved is the first
    # moment validation is possible - and running it in check() alone
    # left two gaps: production sdk() silently ignored an unknown option
    # like `retry.retires`, and check() itself missed the case where the
    # factory is discovered by the LOADER. One call here closes both,
    # because EVERY path to a constructor comes through this line.
    my $resolved = $self->features_of($name);
    my $faults = checkfeatures( $resolved->{merged}, $entry->{descriptor} );
    if (@$faults) {
        Voxgig::Station::Error::fail( $faults->[0]{code},
            join( '; ', map { $_->{message} } @$faults ) );
    }

    # 8.4: compose the merged feature map into the ORDERED form and hand
    # it to the constructor. No new seam - it is the same
    # `options.feature` map connect() already uses for station's own
    # placement, with more in it.
    #
    # Station's own entry is composed AFTER the user merge and always
    # wins, which is why `station` is dropped here and re-added by
    # options(): a config file that can switch off the component reading
    # it is not a surface, it is a trap. `feature.station` is already
    # station_feature_reserved at validation, so this is the second half
    # of one rule rather than a second rule.
    my $fmap = ordered_map();
    for my $row (
        @{
            composefeatures(
                [ grep { 'station' ne $_->{name} }
                      @{ resolveorder( $resolved->{merged} ) } ]
            )
        }
      )
    {
        my $fname = $row->{name};
        my $rest  = ordered_map();
        for my $key ( mapkeys($row) ) {
            next if 'name' eq $key;
            $rest->{$key} = $row->{$key};
        }
        $fmap->{$fname} = $rest;
    }

    my $overmap = ref($overrides) eq 'HASH' ? $overrides : {};
    my $opts = { %{ ref( $block->{options} ) eq 'HASH' ? $block->{options} : {} } };
    $opts->{base} = $block->{base} if defined $block->{base};
    $opts = { %$opts, %$overmap };

    my $overfeature =
      ref( $overmap->{feature} ) eq 'HASH' ? $overmap->{feature} : {};
    my $merged_feature = ordered_map();
    $merged_feature->{$_} = $fmap->{$_}        for mapkeys($fmap);
    $merged_feature->{$_} = $overfeature->{$_} for mapkeys($overfeature);
    $opts->{feature} = $merged_feature;

    # RECORD THE ALIAS, NOT THE FIELDS. Carrying the declared `secret`
    # through the feature options and stopping there leaves `policy`,
    # `base` and everything else behind, so an auto-tagged client
    # silently loses its declared instance's HOSTS ALLOWLIST and falls
    # back to the wider api-level one. Recording what the tag STANDS FOR
    # is one rule that every lookup already goes through.
    #
    # Only when the tag was ASSIGNED - a caller naming its own is naming
    # an instance, not aliasing one.
    $self->{alias_of}{$as} = $name if defined $as && $as ne $name;

    # ...AND THE CARRIED ADAPTER RIDES `extend`, exactly as on connect().
    # The 3.1 retrofit case - an SDK generated before the station
    # feature, which factory_from_module explicitly supports - has no
    # generated feature to consume the `feature.station` activation this
    # path sets, so a declarative sdk() without this either fails on an
    # unknown feature or returns an unregistered, unwrapped client with
    # no credential injection and no events.
    #
    # Safe on a REGENERATED SDK too: the constructor uses its own station
    # feature and skips the extend copy by name, and both delegate to
    # feature_binding, whose _bound_entry check no-ops a second arrival
    # for the same client.
    my $extend = ref( $opts->{extend} ) eq 'ARRAY' ? $opts->{extend} : [];
    my $with_adapter = {
        %$opts,
        extend =>
          [ @$extend, Voxgig::Station::Adapter::adapter_feature( $self, $opts ) ],
    };

    # The instance name reaches the adapter the same way it does on the
    # imperative path, so registration has one spelling (7.5).
    return $entry->{construct}
      ->( $self->options( defined $as ? $as : $name, $with_adapter ) );
}

# 6.2's three paths, in order of preference: self-registration,
# Station->provide, then the loader.
sub resolve_factory {
    my ( $self, $api, $block ) = @_;

    my $direct = factory_for($api);
    return $direct if defined $direct;

    my $pkg = $self->loader_package( $api, $block );
    if ( defined $pkg ) {
        load_sync( $api, $pkg,
            ref($block) eq 'HASH' ? $block->{export} : undef );
        my $loaded = factory_for($api);
        return $loaded if defined $loaded;
    }

    Voxgig::Station::Error::fail( 'station_no_factory',
        'no factory for api "' . $api . '"; either link a generated package '
          . 'that self-registers, call Voxgig::Station->provide("' . $api
          . '", ...), or set `api.' . $api . '.package` so the loader can '
          . 'import it' );
}

# `package` is honoured only from repo-scoped config (6.3), and a
# user-level one is IGNORED WITH A WARNING rather than loaded - it names
# CODE and sits outside the repo's review boundary.
sub loader_package {
    my ( $self, $api, $block ) = @_;
    my $pkg = ref($block) eq 'HASH' ? $block->{package} : undef;
    return undef unless defined $pkg && !ref $pkg && '' ne $pkg;
    return undef
      if exists $self->{opts}{load}
      && defined $self->{opts}{load}
      && !$self->{opts}{load};

    if ( !$self->{repo_scoped} ) {
        $self->_emit(
            {
                t      => _now_ms(),
                kind   => 'station',
                plugin => $api,
                api    => $api,
                meta   => {
                    warn => 'ignoring `package` for api "' . $api
                      . '": it came from a user-level station.json, which is '
                      . 'outside the repo\'s review boundary; everything else '
                      . 'in that config still applies',
                },
            }
        );
        return undef;
    }
    return $pkg;
}

# Perl has ONE module system, so `load` is a SYNCHRONOUS preload of the
# declared packages rather than the ts/js `await station.load()` an
# ESM-only package needs - nothing here has to be awaited before sdk().
# It is kept because a caller written against the contract's surface must
# work unchanged, and because preloading at startup turns a first-request
# import into a startup one.
sub load {
    my ($self) = @_;
    return
      if exists $self->{opts}{load}
      && defined $self->{opts}{load}
      && !$self->{opts}{load};

    for my $name ( sort keys %{ $self->{profile}{sdk} } ) {
        my $block = $self->{profile}{sdk}{$name};
        next if _isfalse( $block->{active} );
        my $api = refapi($name);
        next if defined factory_for($api);
        my $pkg = $self->loader_package( $api, $block );
        next unless defined $pkg;
        load_sync( $api, $pkg, $block->{export} );
    }
    return;
}

# The merged, ordered feature set for one instance, WITH PROVENANCE
# (8.7): which config level set each value. Provenance is the half that
# makes a fleet view usable rather than merely correct - at 26 instances
# "why is retry off here" is the question, and a merged map alone cannot
# answer it.
sub features_of {
    my ( $self, $name ) = @_;
    my $api = refapi($name);

    my $profiles =
      ref( $self->{raw} ) eq 'HASH' && ref( $self->{raw}{profiles} ) eq 'HASH'
      ? $self->{raw}{profiles}
      : {};
    my $base = ref( $profiles->{default} ) eq 'HASH' ? $profiles->{default} : {};
    my $pname = $self->{profile}{name};
    my $overlay =
      'default' eq $pname
      ? {}
      : ( ref( $profiles->{$pname} ) eq 'HASH' ? $profiles->{$pname} : {} );

    my @levels = (
        'default.feature', 'default.api', 'default.sdk',
        $pname . '.feature', $pname . '.api', $pname . '.sdk',
    );
    my $sources = featuresources( $base, $overlay, $api, $name );

    # LAST WRITER PER (feature, key) WINS, and the level that wrote it is
    # what `from` records.
    my %from;
    for my $i ( 0 .. $#$sources ) {
        my $src = $sources->[$i];
        next unless ref($src) eq 'HASH';
        for my $fname ( mapkeys($src) ) {
            my $entry = $src->{$fname};
            next unless ref($entry) eq 'HASH';
            $from{$fname} = {} unless ref( $from{$fname} ) eq 'HASH';
            $from{$fname}{$_} = $levels[$i] for mapkeys($entry);
        }
    }

    my $merged = mergefeatures($sources);

    # Policy budget (design station.md 16): rps/concurrency ceilings ride
    # the SDK `ratelimit` feature, configured by station. Composed HERE,
    # into the merged map every consumer reads, rather than patched in at
    # construction alone - so build() orders it with the ordinary
    # constraint-and-band rules, check()'s 8.5 pass validates it against
    # the SDK's own declaration (a budget on an SDK with no ratelimit
    # feature is station_feature_unknown, not a setting that quietly did
    # nothing), and the fleet view answers "is ratelimit on?" truthfully.
    #
    # `rps` maps to the token bucket's refill `rate` (per second - the
    # same unit); `concurrency` to its capacity `burst`, the number of
    # requests that can be in flight from a full bucket. POLICY WINS over
    # a `feature.ratelimit` config entry on exactly the keys it sets - it
    # is enforcement, not a default - and other tuning keys survive
    # beside it.
    my $block  = $self->block_for($name);
    my $policy = ref($block) eq 'HASH' ? $block->{policy} : undef;
    my $budget = ref($policy) eq 'HASH' ? $policy->{budget} : undef;
    if ( ref($budget) eq 'HASH' ) {
        my $prior = $merged->{ratelimit};
        my $entry = ordered_map();
        if ( ref($prior) eq 'HASH' ) {
            $entry->{$_} = $prior->{$_} for mapkeys($prior);
        }
        $entry->{active} = JSON::PP::true;
        $from{ratelimit} = {} unless ref( $from{ratelimit} ) eq 'HASH';
        $from{ratelimit}{active} = 'policy.budget';
        if ( defined $budget->{rps} ) {
            $entry->{rate} = $budget->{rps};
            $from{ratelimit}{rate} = 'policy.budget';
        }
        if ( defined $budget->{concurrency} ) {
            $entry->{burst} = $budget->{concurrency};
            $from{ratelimit}{burst} = 'policy.budget';
        }
        $merged->{ratelimit} = $entry;
    }

    # THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station` is
    # never in `merged` - `feature.station` is reserved and rejected at
    # validation (8.4) - so without it checkpin finds no station row and
    # is a PERMANENT NO-OP: a constraint like `retry.order.after:
    # 'station'` would be treated as vacuous rather than rejected, and
    # the reported order would omit the one feature whose position is
    # supposedly pinned.
    #
    # Added here rather than into `merged`, which stays the user's own
    # merge result.
    my $fororder = ordered_map();
    $fororder->{$_} = $merged->{$_} for mapkeys($merged);
    $fororder->{station} = { active => JSON::PP::true };

    my $ordered = resolveorder($fororder);
    checkpin($ordered);

    return {
        ordered => [ map { $_->{name} } @$ordered ],
        merged  => $merged,
        from    => \%from,
    };
}

# The fleet feature view: instance x feature, effective options, and
# which config level set each (8.7).
sub features {
    my ( $self, $filter ) = @_;

    # 8.7's documented shape is a MAP, and only the map form can express
    # the question the view exists for: `{feature => 'debug'}` - "is
    # debug on anywhere?", the one that is twenty greps today. The string
    # form is kept as shorthand for "this instance or this api".
    my $loose = ( defined $filter && !ref $filter ) ? 1 : 0;
    my %f =
        $loose                     ? ( instance => $filter, api => $filter )
      : ref($filter) eq 'HASH'     ? %$filter
      :                              ();

    my @rows;
    for my $row ( @{ $self->instances } ) {
        if ($loose) {
            next
              unless !defined $f{instance}
              || $row->{name} eq $f{instance}
              || $row->{api} eq $f{api};
        }
        else {
            next
              if defined $f{instance}
              && $row->{name} ne $f{instance}
              && $row->{api} ne $f{instance};
            next if defined $f{api} && $row->{api} ne $f{api};
        }
        my $of = $self->features_of( $row->{name} );
        push @rows,
          {
            instance => $row->{name},
            api      => $row->{api},
            ordered  => $of->{ordered},
            merged   => $of->{merged},
            from     => $of->{from},
          };
    }

    # `feature` filters the ROWS, not the instances: an instance that
    # does not carry the named feature is not part of the answer, and the
    # rows that remain are narrowed to it so the view answers "where is
    # debug on, and with what" rather than "here is everything, go and
    # look".
    my $want = $f{feature};
    return \@rows unless defined $want;

    my @narrow;
    for my $row (@rows) {
        next unless defined $row->{merged}{$want};
        push @narrow,
          {
            instance => $row->{instance},
            api      => $row->{api},
            ordered  => [ grep { $_ eq $want } @{ $row->{ordered} } ],
            merged   => { $want => $row->{merged}{$want} },
            from     => {
                $want => (
                    ref( $row->{from}{$want} ) eq 'HASH' ? $row->{from}{$want} : {}
                )
            },
          };
    }
    return \@narrow;
}

# Eagerly resolve and construct every ACTIVE declared instance - for CI.
# The point is to turn availability errors, which are deliberately
# deferred to first use, into ONE failure at a moment somebody is
# watching.
sub check {
    my ($self) = @_;
    my ( @ok, @failed );

    for my $row ( @{ $self->instances } ) {
        next unless $row->{active};

        my $faults;
        my $ok = do {
            local $@;
            my $done = eval {

                # 8.5 runs FIRST and needs no construction: the schema
                # arrives with the factory, not with a live client, so a
                # feature typo is a CI failure rather than a setting that
                # quietly did nothing in production.
                my $entry = factory_for( $row->{api} );
                if ( defined $entry ) {
                    my $found = checkfeatures(
                        $self->features_of( $row->{name} )->{merged},
                        $entry->{descriptor} );
                    $faults = $found if @$found;
                }
                $self->sdk( $row->{name} ) unless defined $faults;
                1;
            };
            $done ? undef : $@;
        };

        if ( defined $ok ) {
            my $err = $ok;
            push @failed,
              {
                name => $row->{name},
                code => ( blessed($err) && $err->can('code') ) ? $err->code : undef,
                message => "$err",
              };
            next;
        }

        if ( defined $faults ) {
            push @failed,
              {
                name    => $row->{name},
                code    => $faults->[0]{code},
                message => join( '; ', map { $_->{message} } @$faults ),
              };
            next;
        }

        push @ok, $row->{name};
    }

    return { ok => \@ok, failed => \@failed };
}

# Batch-resolve secrets for ACTIVE instances (5.5).
#
# With no argument it warms the ACTIVE declared instances only, because
# reaching for a credential belonging to a disabled integration is the
# wrong default. warm(names) warms exactly what it is given, inactive
# included, because an explicit name is an explicit request.
sub warm {
    my ( $self, $names ) = @_;

    my @wanted =
      ref($names) eq 'ARRAY'
      ? @$names
      : ( map { $_->{name} } grep { $_->{active} } @{ $self->instances } );

    my ( @warmed, @missed, @plan );
    for my $name (@wanted) {

        # THE REGISTRY IS THE AUTHORITY: a registered instance already
        # carries the resolved name, in-code `secret` feature option
        # included. A NAME NOBODY DECLARED OR REGISTERED IS A MISS, not a
        # lookup - a wider fallback would let a typo like `stripe$prodd`
        # derive a secret name and call the provider, so a nonexistent
        # instance could be reported `warmed` off a shared api-level
        # credential. Registered OR declared, and nothing else.
        my $entry = $self->{registry}{$name};
        if ( !defined $entry && !defined $self->{profile}{sdk}{$name} ) {
            push @missed, $name;
            next;
        }
        my $secretname = defined $entry ? $entry->{secretname} : undef;
        if ( !defined $secretname ) {
            my $block = $self->block_for($name);
            $secretname =
              _first_non_empty( ref($block) eq 'HASH' ? $block->{secret} : undef );
            $secretname = secretname_default( $self->declared_ref($name) )
              unless defined $secretname;
        }
        push @plan, [ $name, $secretname ];
    }

    # ONE RESOLUTION PER DISTINCT SECRET NAME. The broker's resolution
    # cache is keyed by SECRET NAME (5.3), so several instances sharing
    # one api-level `secret` should cost one round-trip.
    #
    # PERL DIVERGENCE, and it is the language's: this port has no async
    # idiom, so the deduplicated names resolve SERIALLY rather than
    # concurrently. The deduplication is what the method mostly exists
    # for and it is kept in full; the concurrency is not available here,
    # and README.md says so.
    my ( %bysecret, @secretorder );
    for my $item (@plan) {
        my ( $name, $secretname ) = @$item;
        push @secretorder, $secretname unless exists $bysecret{$secretname};
        push @{ $bysecret{$secretname} }, $name;
    }

    for my $secretname (@secretorder) {
        my $names_for = $bysecret{$secretname};
        my $ok        = eval {
            $self->{broker}->value( $names_for->[0], $secretname );
            1;
        };
        push @{ $ok ? \@warmed : \@missed }, @$names_for;
    }

    return { warmed => [ sort @warmed ], missed => [ sort @missed ] };
}

# Every DECLARED instance (6.1) - a different question from plugins(),
# and the answers differ routinely: a lazily-started instance is
# `active: true` and not yet live.
sub instances {
    my ($self) = @_;
    my $sdk = $self->{profile}{sdk};
    return [
        map {
            my $name  = $_;
            my $entry = $self->{registry}{$name};
            {
                name => $name,
                api  => refapi($name),

                # `active: false` means BARRED FROM RUNNING - a
                # declaration that stays in the file and here while being
                # refused a client.
                active => _isfalse( $sdk->{$name}{active} ) ? 0 : 1,
                live   => defined $entry ? 1 : 0,
                rung   => defined $entry ? $entry->{rung} : 'none',
                block  => $sdk->{$name},
            }
        } sort keys %$sdk
    ];
}

# 7.4: accepts an INSTANCE name and returns its api's descriptor - one
# object shared by every instance of that api.
sub descriptor_of {
    my ( $self, $name ) = @_;
    my $entry = defined $name ? $self->{registry}{$name} : undef;
    if ( !defined $entry ) {
        Voxgig::Station::Error::fail( 'station_no_plugin',
            'unknown plugin "' . ( defined $name ? $name : '' ) . '"; known: ['
              . join( ', ', @{ $self->{order} } ) . ']' );
    }
    return $entry->{descriptor};
}

sub canonical_descriptor {
    my ( $self, $name ) = @_;
    return canonical_serialize( $self->descriptor_of($name) );
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
        # 7.1: the registry is keyed by INSTANCE, so a status page that
        # projects only `slug` shows two indistinguishable rows for
        # `stripe$test` and `stripe$live` and omits the names it is keyed
        # by - an operator cannot tell which one is unhealthy. `slug`
        # stays for compatibility; `name` and `api` answer the question.
        plugins => [
            map {
                {
                    name => $_->{name},
                    api  => $_->{api},
                    slug => $_->{slug},
                    rung => $_->{rung},
                }
            } @{ $self->plugins }
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

    for my $slug ( sort keys %{ $self->{profile}{sdk} } ) {
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
    my ( $self, $name, $corr, $fullurl, $fetchdef, $status, $started, $bytes ) = @_;
    my ( $host, undef, $path ) = _parse_url($fullurl);
    $self->_emit(
        {
            t      => $started,
            kind   => 'http',
            plugin => $name,
            api    => refapi($name),
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
    my ( $self, $name, $fctx, $err ) = @_;
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

    # 7.3's grouping contract: `plugin` is the INSTANCE and `api` is what
    # groups its siblings. Construction events carried both and the
    # runtime ones did not, so a consumer could group `construct` by api
    # and then get no api for every request, error and hoist from the
    # same client - the grouping working exactly until it was used.
    $self->_emit(
        {
            t      => _now_ms(),
            kind   => 'error',
            plugin => $name,
            api    => refapi($name),
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

# Exactly boolean false - a JSON::PP boolean or struct's own, never a
# plain 0. `false === block.active` in the canonical means the value the
# config file wrote, and a truthiness test here would bar an instance
# whose `active` happened to be the number 0 from a hand-built config.
sub _isfalse {
    my ($val) = @_;
    return 0 unless defined $val && ref $val;
    return 0
      unless JSON::PP::is_bool($val)
      || 'Voxgig::Struct::Bool' eq ref($val);
    return $val ? 0 : 1;
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
